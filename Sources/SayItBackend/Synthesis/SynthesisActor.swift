@preconcurrency import AVFoundation
import Foundation

@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
import SayItCore

actor SynthesisActor: SpeechSynthesizing {
    typealias ModelURLProvider = @Sendable (ModelID) async -> URL?

    private static let kokoroTokenBudget = 500

    private let modelURLProvider: ModelURLProvider
    private let chunker: TextChunker
    private var loadedModel: SpeechGenerationModel?
    private var loadedModelID: ModelID?
    private var loadedTextProcessor: (any TextProcessor)?
    private var currentTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        modelURLProvider: @escaping ModelURLProvider,
        chunker: TextChunker = TextChunker()
    ) {
        self.modelURLProvider = modelURLProvider
        self.chunker = chunker
    }

    func synthesize(
        _ request: SpeechRequest
    ) async -> AsyncThrowingStream<SynthesisEvent, Error> {
        currentTask?.cancel()
        idleUnloadTask?.cancel()

        let (stream, continuation) =
            AsyncThrowingStream<SynthesisEvent, Error>.makeStream()
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: CancellationError())
                return
            }
            do {
                try await self.run(request, continuation: continuation)
            } catch is CancellationError {
                continuation.yield(.cancelled)
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        currentTask = task
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    func cancelCurrentRequest() {
        currentTask?.cancel()
        currentTask = nil
    }

    func unloadModel() {
        currentTask?.cancel()
        idleUnloadTask?.cancel()
        currentTask = nil
        idleUnloadTask = nil
        loadedModel = nil
        loadedModelID = nil
        loadedTextProcessor = nil
    }

    func prepareDependencies(for model: ModelDescriptor) async throws {
        switch model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            let processor = KokoroMultilingualProcessor()
            for language in model.languages {
                try Task.checkCancellation()
                try await processor.prepare(for: language)
            }
        case "kitten", "kitten_tts":
            try await MisakiTextProcessor().prepare()
        default:
            break
        }
    }

    func generateVoiceSample(
        model: ModelDescriptor,
        text: String,
        language: String?,
        tuning: VoiceSynthesisTuning,
        seed: UInt64,
        reference: VoiceReference? = nil
    ) async throws -> GeneratedVoiceSample {
        idleUnloadTask?.cancel()
        try await ensureModelLoaded(model)
        guard let loadedModel else {
            throw SynthesisError.modelNotInstalled
        }
        let referenceAudio = try reference.map {
            try loadReferenceAudio(
                from: $0.audioURL,
                targetSampleRate: Double(loadedModel.sampleRate)
            )
        }
        var parameters = loadedModel.defaultGenerationParameters
        if let value = tuning.parameters["temperature"] {
            parameters.temperature = Float(value)
        }
        if let value = tuning.parameters["topP"] {
            parameters.topP = Float(value)
        }
        if let value = tuning.parameters["topK"] {
            parameters.topK = Int(value.rounded())
        }
        if let value = tuning.parameters["repetitionPenalty"] {
            parameters.repetitionPenalty = Float(value)
        }
        parameters.seed = seed
        applyModelSpecificTuning(tuning, to: loadedModel)
        if let omniVoice = loadedModel as? OmniVoiceModel,
           tuning.parameters["diffusionSteps"] != nil {
            let samples = try await generateOmniVoiceSamples(
                model: omniVoice,
                text: text,
                voice: nil,
                referenceAudio: UncheckedSendable(referenceAudio),
                refText: reference?.transcript,
                language: language,
                parameters: omniVoiceParameters(from: tuning)
            )
            guard !samples.isEmpty else {
                throw SynthesisError.generatedNoAudio
            }
            scheduleIdleUnload()
            return GeneratedVoiceSample(
                samples: samples,
                sampleRate: Double(loadedModel.sampleRate)
            )
        }
        let stream = loadedModel.generateSamplesStream(
            text: text,
            voice: nil,
            refAudio: referenceAudio,
            refText: reference?.transcript,
            language: language,
            generationParameters: parameters
        )
        var samples: [Float] = []
        for try await chunk in stream {
            try Task.checkCancellation()
            samples.append(contentsOf: chunk)
        }
        guard !samples.isEmpty else {
            throw SynthesisError.generatedNoAudio
        }
        scheduleIdleUnload()
        return GeneratedVoiceSample(
            samples: samples,
            sampleRate: Double(loadedModel.sampleRate)
        )
    }

    private func run(
        _ request: SpeechRequest,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws {
        if loadedModelID != request.model.id || loadedModel == nil {
            continuation.yield(.loadingModel(request.model.id))
            try await ensureModelLoaded(request.model)
            continuation.yield(.modelLoaded(request.model.id))
        }

        guard let loadedModel else {
            throw SynthesisError.modelNotInstalled
        }
        try applySpeakingPace(
            request.speakingPace,
            to: loadedModel,
            model: request.model
        )
        applyModelSpecificTuning(request.voiceTuning, to: loadedModel)

        var referenceAudio = try request.voiceReference.map {
            try loadReferenceAudio(
                from: $0.audioURL,
                targetSampleRate: Double(loadedModel.sampleRate)
            )
        }
        var referenceText = request.voiceReference?.transcript
        if request.voiceMode == .automaticStable,
           request.model.capabilities.supportsRandomVoiceSampling {
            continuation.yield(.creatingArticleVoice)
            let anchorText = articleVoiceAnchor(
                language: request.language,
                modelType: request.model.modelType
            )
            var parameters = loadedModel.defaultGenerationParameters
            if let tuning = request.voiceTuning {
                if let value = tuning.parameters["temperature"] {
                    parameters.temperature = Float(value)
                }
                if let value = tuning.parameters["topP"] {
                    parameters.topP = Float(value)
                }
                if let value = tuning.parameters["topK"] {
                    parameters.topK = Int(value.rounded())
                }
                if let value = tuning.parameters["repetitionPenalty"] {
                    parameters.repetitionPenalty = Float(value)
                }
            }
            let anchorVoice = request.model.capabilities.voiceDescription
                ? request.voiceDescription
                : nil
            let anchorStream = loadedModel.generateSamplesStream(
                text: anchorText,
                voice: anchorVoice,
                refAudio: nil,
                refText: nil,
                language: request.language,
                generationParameters: parameters
            )
            var anchorSamples: [Float] = []
            for try await samples in anchorStream {
                try Task.checkCancellation()
                anchorSamples.append(contentsOf: samples)
            }
            guard !anchorSamples.isEmpty else {
                throw SynthesisError.generatedNoAudio
            }
            referenceAudio = MLXArray(anchorSamples)
            referenceText = anchorText
        }

        var chunks = try await chunks(for: request, model: loadedModel)
        var chunkCursor = 0
        var completedChunkCount = 0
        var generatedSamples = 0
        while chunkCursor < chunks.count {
            try Task.checkCancellation()
            let chunk = chunks[chunkCursor]
            continuation.yield(
                .chunkStarted(
                    index: completedChunkCount,
                    text: chunk.text
                )
            )

            let start = ContinuousClock.now
            var chunkSamples = 0
            let usesReference = referenceAudio != nil
                && request.voiceMode != .randomPerParagraph
            let voiceArgument = usesReference
                ? nil
                : request.model.capabilities.voiceDescription
                    ? request.voiceDescription
                    : request.voice
            var parameters = loadedModel.defaultGenerationParameters
            if let tuning = request.voiceTuning {
                if let value = tuning.parameters["temperature"] {
                    parameters.temperature = Float(value)
                }
                if let value = tuning.parameters["topP"] {
                    parameters.topP = Float(value)
                }
                if let value = tuning.parameters["topK"] {
                    parameters.topK = Int(value.rounded())
                }
                if let value = tuning.parameters["repetitionPenalty"] {
                    parameters.repetitionPenalty = Float(value)
                }
            }
            do {
                func emit(_ samples: [Float]) throws {
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { return }

                    if chunk.startsParagraph,
                       generatedSamples > 0,
                       chunkSamples == 0 {
                        let silenceCount = Int(
                            Double(loadedModel.sampleRate) * 0.18
                        )
                        let silence = AudioChunk(
                            requestID: request.id,
                            index: completedChunkCount,
                            samples: Array(repeating: 0, count: silenceCount),
                            sampleRate: Double(loadedModel.sampleRate),
                            startsParagraph: true
                        )
                        continuation.yield(.audio(silence))
                        generatedSamples += silenceCount
                    }

                    let audio = AudioChunk(
                        requestID: request.id,
                        index: completedChunkCount,
                        samples: samples,
                        sampleRate: Double(loadedModel.sampleRate),
                        startsParagraph: chunk.startsParagraph
                    )
                    continuation.yield(.audio(audio))
                    chunkSamples += samples.count
                    generatedSamples += samples.count
                }

                if let omniVoice = loadedModel as? OmniVoiceModel,
                   let tuning = request.voiceTuning,
                   tuning.parameters["diffusionSteps"] != nil {
                    let samples = try await generateOmniVoiceSamples(
                        model: omniVoice,
                        text: chunk.text,
                        voice: voiceArgument,
                        referenceAudio: UncheckedSendable(
                            usesReference ? referenceAudio : nil
                        ),
                        refText: usesReference ? referenceText : nil,
                        language: request.language,
                        parameters: omniVoiceParameters(from: tuning)
                    )
                    try emit(samples)
                } else {
                    let stream = loadedModel.generateSamplesStream(
                        text: chunk.text,
                        voice: voiceArgument,
                        refAudio: usesReference ? referenceAudio : nil,
                        refText: usesReference ? referenceText : nil,
                        language: request.language,
                        generationParameters: parameters,
                        streamingInterval: request.model.playbackMode
                            == .progressive ? 0.32 : 2
                    )
                    for try await samples in stream {
                        try emit(samples)
                    }
                }
            } catch {
                let replacements = chunker.subchunks(of: chunk)
                guard chunkSamples == 0,
                      isInputLengthError(error),
                      replacements.count > 1 else {
                    throw error
                }
                chunks.replaceSubrange(
                    chunkCursor...chunkCursor,
                    with: replacements
                )
                continue
            }

            let duration = start.duration(to: .now)
            let generationDuration = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            continuation.yield(
                .metrics(
                    SynthesisMetrics(
                        chunkIndex: completedChunkCount,
                        generationDuration: generationDuration,
                        audioDuration: Double(chunkSamples)
                            / Double(loadedModel.sampleRate)
                    )
                )
            )
            chunkCursor += 1
            completedChunkCount += 1
        }

        guard generatedSamples > 0 else {
            throw SynthesisError.generatedNoAudio
        }
        continuation.yield(.completed)
        continuation.finish()
        currentTask = nil
        scheduleIdleUnload()
    }

    private func applyModelSpecificTuning(
        _ tuning: VoiceSynthesisTuning?,
        to model: SpeechGenerationModel
    ) {
        guard let chatterbox = model as? ChatterboxModel else { return }
        chatterbox.cfgWeightOverride = tuning?.parameters["cfg"].map(Float.init)
        chatterbox.emotionAdvOverride =
            tuning?.parameters["exaggeration"].map(Float.init)
    }

    private func omniVoiceParameters(
        from tuning: VoiceSynthesisTuning
    ) -> OmniVoiceGenerateParameters {
        OmniVoiceGenerateParameters(
            numStep: Int(
                (tuning.parameters["diffusionSteps"] ?? 32).rounded()
            ),
            guidanceScale: Float(tuning.parameters["guidance"] ?? 2),
            tShift: Float(tuning.parameters["timeShift"] ?? 0.1),
            positionTemperature: Float(
                tuning.parameters["positionTemperature"] ?? 5
            ),
            classTemperature: Float(
                tuning.parameters["classTemperature"] ?? 0
            )
        )
    }

    nonisolated private func generateOmniVoiceSamples(
        model: OmniVoiceModel,
        text: String,
        voice: String?,
        referenceAudio: UncheckedSendable<MLXArray?>,
        refText: String?,
        language: String?,
        parameters: OmniVoiceGenerateParameters
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            ovParameters: parameters
        )
        return audio.asType(.float32).asArray(Float.self)
    }

    private func makeTextProcessor(
        for model: ModelDescriptor
    ) -> (any TextProcessor)? {
        switch model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            KokoroMultilingualProcessor()
        case "kitten", "kitten_tts":
            MisakiTextProcessor()
        default:
            nil
        }
    }

    private func ensureModelLoaded(_ model: ModelDescriptor) async throws {
        if loadedModelID != model.id {
            loadedModel = nil
            loadedModelID = nil
            loadedTextProcessor = nil
        }
        guard loadedModel == nil else { return }
        guard let modelURL = await modelURLProvider(model.id) else {
            throw SynthesisError.modelNotInstalled
        }
        let textProcessor = makeTextProcessor(for: model)
        loadedModel = try await TTS.loadModel(
            modelRepo: modelURL.path,
            modelType: model.modelType,
            textProcessor: textProcessor
        )
        loadedModelID = model.id
        loadedTextProcessor = textProcessor
    }

    private func articleVoiceAnchor(
        language: String?,
        modelType: String
    ) -> String {
        let normalized = language?.lowercased() ?? "en"
        let shortText: String
        switch normalized.split(separator: "-").first {
        case "zh":
            shortText = "清晨的阳光轻轻落在安静的房间里，远处传来鸟儿清脆的歌声。"
        case "ja":
            shortText = "朝の光が静かな部屋にやさしく差し込み、遠くで鳥の声が聞こえました。"
        case "ko":
            shortText = "아침 햇살이 조용한 방 안으로 부드럽게 스며들고 멀리서 새소리가 들렸습니다."
        case "de":
            shortText = "Das Morgenlicht fiel sanft in den stillen Raum, während draußen die ersten Vögel sangen."
        case "fr":
            shortText = "La lumière du matin entrait doucement dans la pièce calme, tandis que les oiseaux chantaient au loin."
        case "es":
            shortText = "La luz de la mañana entraba suavemente en la habitación tranquila mientras cantaban los pájaros."
        case "it":
            shortText = "La luce del mattino entrava dolcemente nella stanza tranquilla mentre gli uccelli cantavano."
        case "pt":
            shortText = "A luz da manhã entrava suavemente na sala tranquila enquanto os pássaros cantavam ao longe."
        case "ru":
            shortText = "Утренний свет мягко наполнял тихую комнату, а вдали уже пели первые птицы."
        default:
            shortText = "Morning light settled softly across the quiet room while the first birds began to sing outside."
        }
        if modelType.lowercased() == "fish_speech" {
            return "\(shortText) The day felt unhurried, clear, and full of small possibilities."
        }
        return shortText
    }

    private func loadReferenceAudio(
        from url: URL,
        targetSampleRate: Double
    ) throws -> MLXArray {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: frameCount
              ) else {
            throw SynthesisError.invalidReferenceAudio
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw SynthesisError.invalidReferenceAudio
        }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channelIndex in 0..<channelCount {
            for sampleIndex in 0..<count {
                mono[sampleIndex] += channels[channelIndex][sampleIndex]
                    / Float(channelCount)
            }
        }
        let sourceRate = buffer.format.sampleRate
        if abs(sourceRate - targetSampleRate) < 1 {
            return MLXArray(mono)
        }
        let outputCount = max(
            Int(Double(mono.count) * targetSampleRate / sourceRate),
            1
        )
        var resampled = [Float](repeating: 0, count: outputCount)
        for outputIndex in 0..<outputCount {
            let sourcePosition = Double(outputIndex) * sourceRate
                / targetSampleRate
            let lower = min(Int(sourcePosition), mono.count - 1)
            let upper = min(lower + 1, mono.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            resampled[outputIndex] =
                mono[lower] * (1 - fraction) + mono[upper] * fraction
        }
        return MLXArray(resampled)
    }

    private func chunks(
        for request: SpeechRequest,
        model: SpeechGenerationModel
    ) async throws -> [SpeechChunk] {
        guard let loadedTextProcessor else {
            return chunker.chunks(for: request.cleanedText.text)
        }

        switch request.model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            let language = request.language
                ?? request.voice.flatMap(
                    KokoroMultilingualProcessor.languageForVoice
                )
                ?? "en-us"
            if let processor =
                loadedTextProcessor as? KokoroMultilingualProcessor {
                try await processor.prepare(for: language)
            }
            return try chunker.chunks(for: request.cleanedText.text) { text in
                let processed = try loadedTextProcessor.process(
                    text: text,
                    language: language
                )
                return processed.unicodeScalars.count
                    <= Self.kokoroTokenBudget
            }
        case "kitten", "kitten_tts":
            let contextLength =
                (model as? KittenTTSModel)?
                    .config.plbert.maxPositionEmbeddings
                ?? 512
            let tokenBudget = max(contextLength - 2, 1)
            return try chunker.chunks(for: request.cleanedText.text) { text in
                let processed = try loadedTextProcessor.process(
                    text: text,
                    language: request.language
                )
                return processed.count <= tokenBudget
            }
        default:
            return chunker.chunks(for: request.cleanedText.text)
        }
    }

    private func isInputLengthError(_ error: Error) -> Bool {
        let message: String
        if case .invalidInput(let detail) = error as? AudioGenerationError {
            message = detail
        } else {
            message = error.localizedDescription
        }
        let normalized = message.lowercased()
        return [
            "input too long",
            "inputs too long",
            "text token count",
            "max_text_tokens",
            "maximum context",
            "context length",
            "sequence length"
        ].contains { normalized.contains($0) }
    }

    private func applySpeakingPace(
        _ pace: SpeakingPace,
        to loadedModel: SpeechGenerationModel,
        model: ModelDescriptor
    ) throws {
        guard model.supportsNativeSpeakingPace else { return }
        switch model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            guard let kokoro = loadedModel as? KokoroModel else {
                throw SynthesisError.speakingPaceUnavailable
            }
            kokoro.speed = Float(pace.rawValue)
        default:
            break
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
