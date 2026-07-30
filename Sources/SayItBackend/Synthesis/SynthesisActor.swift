@preconcurrency import AVFoundation
import Foundation

@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon
import SayItCore

actor SynthesisActor: BackendSpeechSynthesizing {
    typealias ModelURLProvider = @Sendable (ModelID) async -> URL?

    private static let kokoroTokenBudget = 500
    private static let operationGate = SynthesisOperationGate()

    private struct ActiveOperation: Sendable {
        let id: UInt64
        let cancel: @Sendable () -> Void
        let completion: Task<Void, Never>
    }

    private let modelURLProvider: ModelURLProvider
    private var chunker: TextChunker
    private var chunkDelay: Double = 0
    private var paragraphPause: Double = 0.18
    private var idleUnloadDelay: Double = 600
    private var loadedModel: SpeechGenerationModel?
    private var loadedModelID: ModelID?
    private var loadedTextProcessor: (any TextProcessor)?
    private var retainedReferenceAudio: MLXArray?
    private var operationGeneration: UInt64 = 0
    private var activeOperation: ActiveOperation?
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
        let (operationID, previousOperation) = reserveOperation()
        await waitForOperationToFinish(previousOperation)
        guard operationID == operationGeneration else {
            return cancelledStream()
        }

        let (stream, continuation) =
            AsyncThrowingStream<SynthesisEvent, Error>.makeStream()
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: CancellationError())
                return
            }
            do {
                try await Self.operationGate.perform {
                    try await self.runAndQuiesce(
                        request,
                        operationID: operationID,
                        continuation: continuation
                    )
                }
            } catch is CancellationError {
                continuation.yield(.cancelled)
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
            await self.operationDidFinish(operationID)
        }
        activeOperation = ActiveOperation(
            id: operationID,
            cancel: { task.cancel() },
            completion: task
        )
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    func cancelCurrentRequest() async {
        let previousOperation = invalidateCurrentOperation()
        await waitForOperationToFinish(previousOperation)
    }

    func unloadModel() async {
        let (operationID, previousOperation) = reserveOperation()
        await waitForOperationToFinish(previousOperation)
        do {
            try await Self.operationGate.perform {
                await self.releaseLoadedModel(ifCurrent: operationID)
            }
        } catch is CancellationError {
            // A newer operation superseded this unload while it was waiting.
        } catch {
            assertionFailure("Unexpected model unload failure: \(error)")
        }
    }

    func updateConfiguration(
        chunkTarget: Int,
        chunkDelay: Double,
        paragraphPause: Double,
        idleUnloadDelay: Double
    ) {
        chunker = TextChunker(
            targetCharacterCount: chunkTarget,
            hardCharacterLimit: max(1_000, chunkTarget + 350)
        )
        self.chunkDelay = max(chunkDelay, 0)
        self.paragraphPause = max(paragraphPause, 0)
        self.idleUnloadDelay = max(idleUnloadDelay, 0)
        if idleUnloadDelay <= 0 {
            idleUnloadTask?.cancel()
            idleUnloadTask = nil
        }
    }

    func prepareDependencies(for model: ModelDescriptor) async throws {
        try await Self.operationGate.perform {
            try await self.performDependencyPreparation(for: model)
        }
    }

    private func performDependencyPreparation(
        for model: ModelDescriptor
    ) async throws {
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
        let (operationID, previousOperation) = reserveOperation()
        await waitForOperationToFinish(previousOperation)
        guard operationID == operationGeneration else {
            throw CancellationError()
        }

        let resultTask = Task { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            do {
                let result = try await Self.operationGate.perform {
                    try await self.generateVoiceSampleAndQuiesce(
                        model: model,
                        text: text,
                        language: language,
                        tuning: tuning,
                        seed: seed,
                        reference: reference,
                        operationID: operationID
                    )
                }
                await self.operationDidFinish(operationID)
                return result
            } catch {
                await self.operationDidFinish(operationID)
                throw error
            }
        }
        let completion = Task {
            _ = try? await resultTask.value
        }
        activeOperation = ActiveOperation(
            id: operationID,
            cancel: { resultTask.cancel() },
            completion: completion
        )

        return try await withTaskCancellationHandler {
            try await resultTask.value
        } onCancel: {
            resultTask.cancel()
        }
    }

    private func performVoiceSampleGeneration(
        model: ModelDescriptor,
        text: String,
        language: String?,
        tuning: VoiceSynthesisTuning,
        seed: UInt64,
        reference: VoiceReference?,
        operationID: UInt64
    ) async throws -> GeneratedVoiceSample {
        try await ensureModelLoaded(model, operationID: operationID)
        try checkOperation(operationID)
        guard let loadedModel else {
            throw SynthesisError.modelNotInstalled
        }
        // Retain each reference array until the next one is allocated: the
        // pinned Qwen3 wrapper caches reference conditioning by the array's
        // ObjectIdentifier without retaining it, so a freed address reused by
        // the next array would falsely hit that cache and replay stale audio.
        var referenceAudio: MLXArray?
        if let reference {
            let audio = try loadReferenceAudio(
                from: reference.audioURL,
                targetSampleRate: Double(loadedModel.sampleRate)
            )
            retainedReferenceAudio = audio
            referenceAudio = audio
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
            let samples = try await SerializedSpeechModel(omniVoice)
                .generateOmniVoiceSamples(
                    text: text,
                    voice: nil,
                    referenceAudio: SerializedMLXArray(referenceAudio),
                    refText: reference?.transcript,
                    language: language,
                    parameters: omniVoiceParameters(from: tuning)
                )
            try checkOperation(operationID)
            guard !samples.isEmpty else {
                throw SynthesisError.generatedNoAudio
            }
            return GeneratedVoiceSample(
                samples: samples,
                sampleRate: Double(loadedModel.sampleRate)
            )
        }
        let samples = try await SerializedSpeechModel(loadedModel)
            .generateSamples(
                text: text,
                voice: nil,
                referenceAudio: SerializedMLXArray(referenceAudio),
                refText: reference?.transcript,
                language: language,
                generationParameters: parameters
            )
        try checkOperation(operationID)
        guard !samples.isEmpty else {
            throw SynthesisError.generatedNoAudio
        }
        return GeneratedVoiceSample(
            samples: samples,
            sampleRate: Double(loadedModel.sampleRate)
        )
    }

    private func run(
        _ request: SpeechRequest,
        operationID: UInt64,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws {
        try checkOperation(operationID)
        if loadedModelID != request.model.id || loadedModel == nil {
            continuation.yield(.loadingModel(request.model.id))
            try await ensureModelLoaded(
                request.model,
                operationID: operationID
            )
            try checkOperation(operationID)
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
        if referenceAudio != nil {
            retainedReferenceAudio = referenceAudio
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
            let anchorSamples = try await SerializedSpeechModel(loadedModel)
                .generateSamples(
                    text: anchorText,
                    voice: anchorVoice,
                    referenceAudio: SerializedMLXArray(nil),
                    refText: nil,
                    language: request.language,
                    generationParameters: parameters
                )
            try checkOperation(operationID)
            guard !anchorSamples.isEmpty else {
                throw SynthesisError.generatedNoAudio
            }
            referenceAudio = MLXArray(anchorSamples)
            retainedReferenceAudio = referenceAudio
            referenceText = anchorText
        }

        var chunks = try await chunks(for: request, model: loadedModel)
        var chunkCursor = 0
        var completedChunkCount = 0
        var generatedSamples = 0
        while chunkCursor < chunks.count {
            try Task.checkCancellation()
            if chunkCursor > 0, chunkDelay > 0 {
                try await Task.sleep(for: .seconds(chunkDelay))
            }
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
                       chunkSamples == 0,
                       paragraphPause > 0 {
                        let silenceCount = Int(
                            Double(loadedModel.sampleRate) * paragraphPause
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
                    let samples = try await SerializedSpeechModel(omniVoice)
                        .generateOmniVoiceSamples(
                            text: chunk.text,
                            voice: voiceArgument,
                            referenceAudio: SerializedMLXArray(
                                usesReference ? referenceAudio : nil
                            ),
                            refText: usesReference ? referenceText : nil,
                            language: request.language,
                            parameters: omniVoiceParameters(from: tuning)
                        )
                    try checkOperation(operationID)
                    try emit(samples)
                } else {
                    let stream = SerializedSpeechModel(loadedModel)
                        .generateSamplesStream(
                        text: chunk.text,
                        voice: voiceArgument,
                        referenceAudio: SerializedMLXArray(
                            usesReference ? referenceAudio : nil
                        ),
                        refText: usesReference ? referenceText : nil,
                        language: request.language,
                        generationParameters: parameters,
                        streamingInterval: request.model.playbackMode
                            == .progressive ? 0.32 : 2
                    )
                    for try await samples in stream {
                        try checkOperation(operationID)
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

    private func ensureModelLoaded(
        _ model: ModelDescriptor,
        operationID: UInt64
    ) async throws {
        try checkOperation(operationID)
        if loadedModelID != model.id {
            releaseLoadedModel()
        }
        guard loadedModel == nil else { return }
        let modelURL = await modelURLProvider(model.id)
        try checkOperation(operationID)
        guard let modelURL else {
            throw SynthesisError.modelNotInstalled
        }
        let textProcessor = makeTextProcessor(for: model)
        let candidate: SpeechGenerationModel
        do {
            candidate = try await TTS.loadModel(
                modelRepo: modelURL.path,
                modelType: model.modelType,
                textProcessor: textProcessor
            )
        } catch {
            Stream.gpu.synchronize()
            Memory.clearCache()
            throw error
        }
        do {
            try checkOperation(operationID)
        } catch {
            Stream.gpu.synchronize()
            withExtendedLifetime(candidate) {}
            Memory.clearCache()
            throw error
        }
        loadedModel = candidate
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

    private func reserveOperation() -> (UInt64, ActiveOperation?) {
        operationGeneration &+= 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        let previousOperation = activeOperation
        previousOperation?.cancel()
        return (operationGeneration, previousOperation)
    }

    private func invalidateCurrentOperation() -> ActiveOperation? {
        operationGeneration &+= 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        let previousOperation = activeOperation
        previousOperation?.cancel()
        return previousOperation
    }

    private func waitForOperationToFinish(
        _ operation: ActiveOperation?
    ) async {
        guard let operation else { return }
        await operation.completion.value
        if activeOperation?.id == operation.id {
            activeOperation = nil
        }
    }

    private func checkOperation(_ operationID: UInt64) throws {
        try Task.checkCancellation()
        guard operationID == operationGeneration,
              activeOperation?.id == operationID else {
            throw CancellationError()
        }
    }

    private func operationDidFinish(_ operationID: UInt64) {
        guard activeOperation?.id == operationID else { return }
        activeOperation = nil
        guard operationID == operationGeneration else { return }
        scheduleIdleUnload(for: operationID)
    }

    private func cancelledStream()
        -> AsyncThrowingStream<SynthesisEvent, Error> {
        let (stream, continuation) =
            AsyncThrowingStream<SynthesisEvent, Error>.makeStream()
        continuation.yield(.cancelled)
        continuation.finish(throwing: CancellationError())
        return stream
    }

    private func runAndQuiesce(
        _ request: SpeechRequest,
        operationID: UInt64,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws {
        do {
            try await run(
                request,
                operationID: operationID,
                continuation: continuation
            )
            synchronizeMLXIfLoaded()
        } catch {
            synchronizeMLXIfLoaded()
            throw error
        }
    }

    private func generateVoiceSampleAndQuiesce(
        model: ModelDescriptor,
        text: String,
        language: String?,
        tuning: VoiceSynthesisTuning,
        seed: UInt64,
        reference: VoiceReference?,
        operationID: UInt64
    ) async throws -> GeneratedVoiceSample {
        do {
            let result = try await performVoiceSampleGeneration(
                model: model,
                text: text,
                language: language,
                tuning: tuning,
                seed: seed,
                reference: reference,
                operationID: operationID
            )
            synchronizeMLXIfLoaded()
            return result
        } catch {
            synchronizeMLXIfLoaded()
            throw error
        }
    }

    private func releaseLoadedModel(ifCurrent operationID: UInt64) {
        guard operationID == operationGeneration else { return }
        releaseLoadedModel()
    }

    private func releaseLoadedModel() {
        guard loadedModel != nil || retainedReferenceAudio != nil else {
            loadedModelID = nil
            loadedTextProcessor = nil
            return
        }
        Stream.gpu.synchronize()
        loadedModel = nil
        loadedModelID = nil
        loadedTextProcessor = nil
        retainedReferenceAudio = nil
        Memory.clearCache()
    }

    private func synchronizeMLXIfLoaded() {
        guard loadedModel != nil || retainedReferenceAudio != nil else { return }
        Stream.gpu.synchronize()
    }

    private func scheduleIdleUnload(for operationID: UInt64) {
        idleUnloadTask?.cancel()
        guard idleUnloadDelay > 0 else { return }
        let delay = idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.idleUnloadTimerFired(for: operationID)
        }
    }

    private func idleUnloadTimerFired(for operationID: UInt64) async {
        guard operationID == operationGeneration,
              activeOperation == nil else { return }
        idleUnloadTask = nil
        await unloadModel()
    }
}

actor SynthesisOperationGate {
    private var generation: UInt64 = 0
    private var tail: (
        id: UInt64,
        completion: Task<Void, Never>
    )?

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        generation &+= 1
        let operationID = generation
        let predecessor = tail?.completion
        let task = Task {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        let completion = Task {
            _ = try? await task.value
        }
        tail = (operationID, completion)

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            operationFinished(operationID)
            return value
        } catch {
            operationFinished(operationID)
            throw error
        }
    }

    private func operationFinished(_ operationID: UInt64) {
        guard tail?.id == operationID else { return }
        tail = nil
    }
}

/// MLX Audio's public model protocol is not concurrency annotated. Instances
/// are only accessed while `SynthesisOperationGate` is held, and this adapter
/// prevents the non-Sendable model and arrays from escaping that critical
/// section. Callers only receive materialized, Sendable sample buffers.
private final class SerializedSpeechModel: @unchecked Sendable {
    private let model: SpeechGenerationModel

    init(_ model: SpeechGenerationModel) {
        self.model = model
    }

    func generateSamples(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            generationParameters: generationParameters
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        try Task.checkCancellation()
        return samples
    }

    func generateOmniVoiceSamples(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        parameters: OmniVoiceGenerateParameters
    ) async throws -> [Float] {
        guard let model = model as? OmniVoiceModel else {
            throw SynthesisError.generatedNoAudio
        }
        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            ovParameters: parameters
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        try Task.checkCancellation()
        return samples
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<[Float], Error> {
        model.generateSamplesStream(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            generationParameters: generationParameters,
            streamingInterval: streamingInterval
        )
    }
}

/// See `SerializedSpeechModel`: this value never leaves the globally
/// serialized MLX operation.
private struct SerializedMLXArray: @unchecked Sendable {
    let value: MLXArray?

    init(_ value: MLXArray?) {
        self.value = value
    }
}
