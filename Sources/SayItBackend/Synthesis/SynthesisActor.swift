import Accelerate
@preconcurrency import AVFoundation
import Foundation

@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import SayItCore
import SayItProtocol

actor SynthesisActor: BackendSpeechSynthesizing {
    typealias ModelURLProvider = @Sendable (ModelID) async -> URL?

    private static let kokoroTokenBudget = 500
    private static let minimumListItemPause: TimeInterval = 0.25
    private static let maxCachedReferenceAudios = 4
    private static let maxCachedQwen3Conditionings = 4
    private static let fastStartFirstChunkTarget = 160
    private static let fastStartFirstChunkThreshold = 200
    // MLX Audio caps Orpheus at 1,200 audio tokens, roughly 15 seconds.
    // Short inputs let each request reach EOS instead of truncating mid-block.
    static let orpheusChunker = TextChunker(
        targetCharacterCount: 90,
        hardCharacterLimit: 120
    )
    private static let operationGate = SynthesisOperationGate()
    // Read once, before any model narrows it, so other models get it back.
    private static let defaultMLXCacheLimit = Memory.cacheLimit

    private struct ActiveOperation: Sendable {
        let id: UInt64
        let cancel: @Sendable () -> Void
        let completion: Task<Void, Never>
        let preloadingModelID: ModelID?
    }

    private struct ReferenceAudioCacheKey: Hashable {
        let path: String
        let sampleRate: Int
        let fileSize: Int64
        let modifiedTimeInterval: TimeInterval
    }

    private struct Qwen3ConditioningCacheKey: Hashable {
        let modelID: ObjectIdentifier
        let audioID: ObjectIdentifier
        let transcript: String
        let language: String
    }

    private let modelURLProvider: ModelURLProvider
    private var chunker: TextChunker
    private var chunkDelay: Double = 0
    private var paragraphPause: Double = 0.18
    private var idleUnloadDelay: Double = 600
    private var loadedModel: SpeechGenerationModel?
    private var loadedModelID: ModelID?
    private var loadedModelURL: URL?
    private var loadedTextProcessor: (any TextProcessor)?
    private var retainedReferenceAudio: MLXArray?
    private var referenceAudioCache: [ReferenceAudioCacheKey: MLXArray] = [:]
    private var referenceAudioCacheOrder: [ReferenceAudioCacheKey] = []
    private var qwen3ConditioningCache: [Qwen3ConditioningCacheKey: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
    private var qwen3ConditioningCacheOrder: [Qwen3ConditioningCacheKey] = []
    private var operationGeneration: UInt64 = 0
    private var requestArrivalOrder: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        modelURLProvider: @escaping ModelURLProvider,
        chunker: TextChunker = TextChunker()
    ) {
        self.modelURLProvider = modelURLProvider
        self.chunker = chunker
    }

    /// Insert silence at list boundaries even when paragraph pauses are disabled.
    static func pauseFrameCount(
        sampleRate: Double,
        paragraphPause: Double,
        startsListItem: Bool
    ) -> Int {
        let minimumPause = startsListItem ? minimumListItemPause : 0
        return Int(sampleRate * max(paragraphPause, minimumPause))
    }

    func synthesize(
        _ request: SpeechRequest
    ) async -> AsyncThrowingStream<SynthesisEvent, Error> {
        requestArrivalOrder &+= 1
        let arrivalOrder = requestArrivalOrder
        if let active = activeOperation, active.preloadingModelID == request.model.id {
            await waitForOperationToFinish(active)
            guard arrivalOrder == requestArrivalOrder else {
                return cancelledStream()
            }
        }

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
            completion: task,
            preloadingModelID: nil
        )
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    func preloadModel(
        _ model: ModelDescriptor,
        voice: String?,
        voiceReference: VoiceReference?,
        language: String?
    ) async {
        guard activeOperation == nil else { return }
        let (operationID, _) = reserveOperation()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.operationGate.perform {
                    try await self.performPreload(
                        model,
                        voice: voice,
                        voiceReference: voiceReference,
                        language: language,
                        operationID: operationID
                    )
                }
            } catch {
                // Preloading is opportunistic; real synthesis surfaces errors.
            }
            await self.operationDidFinish(operationID)
        }
        activeOperation = ActiveOperation(
            id: operationID,
            cancel: { task.cancel() },
            completion: task,
            preloadingModelID: model.id
        )
    }

    func cancelCurrentRequest() async {
        requestArrivalOrder &+= 1
        let previousOperation = invalidateCurrentOperation()
        await waitForOperationToFinish(previousOperation)
    }

    func unloadModel() async {
        requestArrivalOrder &+= 1
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

    private func performPreload(
        _ model: ModelDescriptor,
        voice: String?,
        voiceReference: VoiceReference?,
        language: String?,
        operationID: UInt64
    ) async throws {
        try await ensureModelLoaded(model, operationID: operationID)
        try checkOperation(operationID)
        guard let loadedModel else { return }

        if let pocketTTS = loadedModel as? PocketTTSModel,
           let modelURL = loadedModelURL {
            let embeddingVoice = try? phononEmbeddingVoice(voiceReference, model: model)
            let referenceAudio: MLXArray?
            if let voiceReference, voiceReference.kind == .audio {
                referenceAudio = try? cachedReferenceAudio(
                    from: voiceReference.audioURL,
                    targetSampleRate: Double(loadedModel.sampleRate)
                )
            } else {
                referenceAudio = nil
            }
            if let referenceAudio {
                retainedReferenceAudio = referenceAudio
            }
            try? PocketTTSStreamRunner.warmVoice(
                model: pocketTTS,
                modelFolder: modelURL,
                voice: embeddingVoice ?? (referenceAudio == nil ? voice : nil),
                referenceAudio: referenceAudio
            )
        } else if let cachingProcessor = loadedTextProcessor as? CachingTextProcessor {
            let modelType = model.modelType.lowercased()
            if modelType == "kokoro" || modelType == "kokoro_tts" {
                let targetLanguage = language
                    ?? voice.flatMap(KokoroMultilingualProcessor.languageForVoice)
                    ?? "en-us"
                try? await cachingProcessor.prepare(for: targetLanguage)
            } else if modelType == "kitten" || modelType == "kitten_tts" {
                try? await cachingProcessor.prepare()
            }
        } else if let qwen3 = loadedModel as? Qwen3TTSModel,
                  let voiceReference,
                  voiceReference.kind == .audio,
                  let transcript = voiceReference.transcript,
                  !transcript.isEmpty,
                  let referenceAudio = try? cachedReferenceAudio(
                      from: voiceReference.audioURL,
                      targetSampleRate: Double(loadedModel.sampleRate)
                  ) {
            retainedReferenceAudio = referenceAudio
            _ = try? cachedQwen3Conditioning(
                for: qwen3,
                referenceAudio: referenceAudio,
                transcript: transcript,
                language: language
            )
        }
        try checkOperation(operationID)
        synchronizeMLXAfterSuccess()
    }

    func generateVoiceSample(
        model: ModelDescriptor,
        text: String,
        language: String?,
        tuning: VoiceSynthesisTuning,
        seed: UInt64,
        reference: VoiceReference? = nil
    ) async throws -> GeneratedVoiceSample {
        requestArrivalOrder &+= 1
        let arrivalOrder = requestArrivalOrder
        if let active = activeOperation, active.preloadingModelID == model.id {
            await waitForOperationToFinish(active)
            guard arrivalOrder == requestArrivalOrder else {
                throw CancellationError()
            }
        }

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
            completion: completion,
            preloadingModelID: nil
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
        let embeddingVoice = try phononEmbeddingVoice(reference, model: model)
        if let reference, reference.kind == .audio {
            let audio = try cachedReferenceAudio(
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
        let samples: [Float]
        if let pocketTTS = loadedModel as? PocketTTSModel,
           let modelURL = loadedModelURL {
            samples = try PocketTTSStreamRunner.generateSamples(
                model: pocketTTS,
                modelFolder: modelURL,
                text: text,
                voice: embeddingVoice,
                referenceAudio: referenceAudio,
                generationParameters: parameters
            )
        } else {
            samples = try await SerializedSpeechModel(loadedModel)
                .generateSamples(
                    text: text,
                    voice: embeddingVoice,
                    referenceAudio: SerializedMLXArray(referenceAudio),
                    refText: reference?.transcript,
                    language: language,
                    generationParameters: parameters
                )
        }
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
        let requestStarted = ContinuousClock.now
        func recordTiming(_ phase: SynthesisTiming.Phase, since start: ContinuousClock.Instant) {
            let duration = start.duration(to: .now)
            continuation.yield(.timing(SynthesisTiming(phase: phase,
                duration: Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18)))
        }
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
        recordTiming(.modelLoad, since: requestStarted)
        let voiceStarted = ContinuousClock.now

        guard let loadedModel else {
            throw SynthesisError.modelNotInstalled
        }
        try applySpeakingPace(
            request.speakingPace,
            to: loadedModel,
            model: request.model
        )
        applyModelSpecificTuning(request.voiceTuning, to: loadedModel)

        let embeddingVoice = try phononEmbeddingVoice(request.voiceReference, model: request.model)
        var referenceAudio = try request.voiceReference.flatMap { reference -> MLXArray? in
            guard reference.kind == .audio else { return nil }
            return try cachedReferenceAudio(
                from: reference.audioURL,
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

        recordTiming(.voicePreparation, since: voiceStarted)
        let listItemStartOffsets = Set(
            request.cleanedText.listItemStartOffsets ?? []
        )
        let paragraphBreakStartOffsets = Set(
            request.cleanedText.paragraphBreakStartOffsets ?? []
        )
        let modelTypeLower = request.model.modelType.lowercased()
        let usesShortChunks = ["orpheus", "orpheus_tts"].contains(modelTypeLower)
        var chunks = try (usesShortChunks ? Self.orpheusChunker : chunker).chunks(
            for: request.cleanedText.text,
            separatesParagraphs: usesShortChunks || request.voiceMode == .randomPerParagraph,
            listItemStartOffsets: listItemStartOffsets,
            paragraphBreakStartOffsets: paragraphBreakStartOffsets,
            checkingCancellation: Task.checkCancellation
        )
        if !chunks.isEmpty,
           Self.usesFastStartFirstChunk(modelType: modelTypeLower) {
            let split = chunker.splitFirstChunkForFastStart(
                chunks[0],
                targetCharacterCount: Self.fastStartFirstChunkTarget,
                minimumLengthToSplit: Self.fastStartFirstChunkThreshold
            )
            if split.count > 1 {
                chunks.replaceSubrange(0...0, with: split)
            }
        }
        var conditioner = try PCMStreamConditioner(
            sampleRate: Double(loadedModel.sampleRate)
        )
        let streamingInterval: Double = request.model.playbackMode == .progressive ? 0.32 : 0.8
        let emitsAdaptiveProgress = loadedModel is DramaLibraryModel
            || request.model.playbackMode == .adaptive
        var chunkCursor = 0
        var completedChunkCount = 0
        var generatedSamples = 0
        while chunkCursor < chunks.count {
            try Task.checkCancellation()
            if chunkCursor > 0, chunkDelay > 0 {
                try await Task.sleep(for: .seconds(chunkDelay))
            }
            // Fit only the next logical chunk. Phonemizing a whole article here
            // would delay first audio even though the model consumes one chunk.
            let pieces = try await fittingPieces(
                for: chunks[chunkCursor], request: request, model: loadedModel
            )
            chunks.replaceSubrange(chunkCursor...chunkCursor, with: pieces)
            let chunk = chunks[chunkCursor]
            continuation.yield(
                .chunkStarted(
                    index: completedChunkCount,
                    chunk: chunk
                )
            )

            let start = ContinuousClock.now
            var chunkSamples = 0
            var deliveryCount = 0
            var previousDeliverySeconds = 0.0
            var maximumDeliveryGap = 0.0
            var initialGenerationDuration = 0.0
            var initialAudioDuration = 0.0
            var recentDeliveries: [(seconds: Double, audio: Double)] = []
            let conditionerBeforeChunk = conditioner
            let usesReference = referenceAudio != nil
                && request.voiceMode != .randomPerParagraph
            let voiceArgument = embeddingVoice ?? (usesReference
                ? nil
                : request.model.capabilities.voiceDescription
                    ? request.voiceDescription
                    : request.voice)
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

                    let pauseFrameCount = chunk.startsParagraph
                        && generatedSamples > 0
                        && chunkSamples == 0
                        ? Self.pauseFrameCount(
                            sampleRate: Double(loadedModel.sampleRate),
                            paragraphPause: paragraphPause,
                            startsListItem: listItemStartOffsets.contains(
                                chunk.sourceRange.lowerBound
                            )
                        )
                        : 0
                    let speechStartFrames = conditioner.speechStartFrameOffset(
                        logicalChunkIndex: completedChunkCount,
                        startsParagraph: chunk.startsParagraph,
                        paragraphPauseFrameCount: pauseFrameCount
                    )
                    let conditioned = try conditioner.append(
                        samples,
                        logicalChunkIndex: completedChunkCount,
                        startsParagraph: chunk.startsParagraph,
                        paragraphPauseFrameCount: pauseFrameCount
                    )
                    guard !conditioned.isEmpty else { return }

                    let audio = AudioChunk(
                        requestID: request.id,
                        index: completedChunkCount,
                        samples: conditioned,
                        sampleRate: Double(loadedModel.sampleRate),
                        startsParagraph: chunk.startsParagraph,
                        speechStartOffset: Double(speechStartFrames)
                            / Double(loadedModel.sampleRate)
                    )
                    if generatedSamples == 0 {
                        recordTiming(.firstAudio, since: requestStarted)
                    }
                    continuation.yield(.audio(audio))
                    chunkSamples += conditioned.count
                    generatedSamples += conditioned.count
                    if emitsAdaptiveProgress {
                        // Observe existing output only; sampling and PCM stay unchanged.
                        let elapsed = start.duration(to: .now)
                        let seconds = Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1e18
                        let gap = max(seconds - previousDeliverySeconds, 0)
                        previousDeliverySeconds = seconds
                        maximumDeliveryGap = max(maximumDeliveryGap, gap)
                        if deliveryCount == 0 {
                            initialGenerationDuration = seconds
                            initialAudioDuration = Double(conditioned.count) / Double(loadedModel.sampleRate)
                        }
                        deliveryCount += 1
                        recentDeliveries.append((gap, Double(conditioned.count) / Double(loadedModel.sampleRate)))
                        if recentDeliveries.count > 4 { recentDeliveries.removeFirst() }
                        let recentSeconds = recentDeliveries.reduce(0) { $0 + $1.seconds }
                        let recentAudio = recentDeliveries.reduce(0) { $0 + $1.audio }
                        let delivered = Double(chunkSamples) / Double(loadedModel.sampleRate)
                        continuation.yield(.progress(SynthesisProgress(
                            chunkIndex: completedChunkCount, generatedAudioDuration: delivered,
                            generationDuration: seconds, recentRealTimeFactor: recentSeconds / recentAudio,
                            deliveredAudioPieces: deliveryCount,
                            maximumDeliveryGap: maximumDeliveryGap,
                            initialGenerationDuration: initialGenerationDuration,
                            initialAudioDuration: initialAudioDuration)))
                    }
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
                } else if loadedModel is KokoroModel {
                    // Kokoro emits a whole text chunk. Materialize it in the
                    // generating task; the upstream stream proxy can evaluate
                    // its lazy graph on a thread without its internal GPU streams.
                    let samples = try await SerializedSpeechModel(loadedModel)
                        .generateSamples(
                            text: chunk.text,
                            voice: voiceArgument,
                            referenceAudio: SerializedMLXArray(
                                usesReference ? referenceAudio : nil
                            ),
                            refText: usesReference ? referenceText : nil,
                            language: request.language,
                            generationParameters: parameters
                        )
                    try checkOperation(operationID)
                    try emit(samples)
                } else if let drama = loadedModel as? DramaLibraryModel {
                    let stream = SerializedSpeechModel(drama)
                        .generateDramaSamplesStream(
                            text: chunk.text,
                            referenceAudio: SerializedMLXArray(
                                usesReference ? referenceAudio : nil
                            ),
                            refText: usesReference ? referenceText : nil,
                            generationParameters: parameters,
                            streamingFrames: chunkCursor == 0 ? 16 : 24
                        )
                    for try await samples in stream {
                        try checkOperation(operationID)
                        try emit(samples)
                    }
                } else if let pocketTTS = loadedModel as? PocketTTSModel,
                          let modelURL = loadedModelURL {
                    let stream = PocketTTSStreamRunner.generateSamplesStream(
                        model: pocketTTS,
                        modelFolder: modelURL,
                        text: chunk.text,
                        voice: voiceArgument,
                        referenceAudio: usesReference ? referenceAudio : nil,
                        generationParameters: parameters,
                        streamingInterval: streamingInterval
                    )
                    for try await samples in stream {
                        try checkOperation(operationID)
                        try emit(samples)
                    }
                } else if let qwen3 = loadedModel as? Qwen3TTSModel,
                          usesReference,
                          let referenceAudio,
                          let referenceText,
                          !referenceText.isEmpty {
                    let conditioning = try cachedQwen3Conditioning(
                        for: qwen3,
                        referenceAudio: referenceAudio,
                        transcript: referenceText,
                        language: request.language
                    )
                    let stream = SerializedSpeechModel(qwen3)
                        .generateQwen3SamplesStream(
                            text: chunk.text,
                            conditioning: conditioning,
                            generationParameters: parameters,
                            streamingInterval: streamingInterval
                        )
                    for try await samples in stream {
                        try checkOperation(operationID)
                        try emit(samples)
                    }
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
                        streamingInterval: streamingInterval
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
                conditioner = conditionerBeforeChunk
                chunks.replaceSubrange(
                    chunkCursor...chunkCursor,
                    with: replacements
                )
                continue
            }

            try checkOperation(operationID)
            if chunkCursor == chunks.count - 1 {
                let tail = conditioner.finish()
                if !tail.isEmpty {
                    if generatedSamples == 0 {
                        recordTiming(.firstAudio, since: requestStarted)
                    }
                    continuation.yield(
                        .audio(
                            AudioChunk(
                                requestID: request.id,
                                index: completedChunkCount,
                                samples: tail,
                                sampleRate: Double(loadedModel.sampleRate),
                                startsParagraph: chunk.startsParagraph
                            )
                        )
                    )
                    chunkSamples += tail.count
                    generatedSamples += tail.count
                }
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
                            / Double(loadedModel.sampleRate),
                        trailingAudioDuration: Double(conditioner.retainedFrameCount)
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
        recordTiming(.synthesisTotal, since: requestStarted)
        continuation.yield(.completed)
        continuation.finish()
    }

    private static func usesFastStartFirstChunk(modelType: String) -> Bool {
        switch modelType {
        case "kokoro", "kokoro_tts", "kitten", "kitten_tts", "omnivoice", "soprano", "soprano_tts":
            true
        default:
            false
        }
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
            CachingTextProcessor(KokoroMultilingualProcessor())
        case "kitten", "kitten_tts":
            CachingTextProcessor(MisakiTextProcessor())
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
            try checkOperation(operationID)
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
            switch model.modelType.lowercased() {
            case "fish_drama3":
                candidate = try await DramaLibraryModel.fromDirectory(modelURL)
            case "omnivoice":
                let hubCache = ProcessInfo.processInfo.environment[
                    "HF_HUB_CACHE"
                ].map {
                    URL(filePath: $0, directoryHint: .isDirectory)
                } ?? modelURL.deletingLastPathComponent()
                let repository = try MLXAudioLocalModelBridge
                    .repositoryIdentifier(
                        modelType: model.modelType,
                        repository: model.repository,
                        localDirectory: modelURL,
                        hubCache: hubCache
                    ) ?? model.repository
                candidate = try await TTS.loadModel(
                    modelRepo: repository,
                    modelType: model.modelType,
                    textProcessor: textProcessor
                )
            case "kitten", "kitten_tts":
                try KittenVoiceArchiveConverter.prepareVoices(in: modelURL)
                candidate = try await TTS.loadModel(
                    modelRepo: modelURL.path,
                    modelType: model.modelType,
                    textProcessor: textProcessor
                )
            case "soprano", "soprano_tts":
                candidate = try await SopranoModel.fromModelDirectory(
                    modelURL,
                    repo: model.repository
                )
            default:
                candidate = try await TTS.loadModel(
                    modelRepo: modelURL.path,
                    modelType: SupportedModelTypes.loaderType(for: model.modelType),
                    textProcessor: textProcessor
                )
            }
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
        Memory.cacheLimit = MLXCachePolicy.cacheLimit(
            forModelType: model.modelType,
            defaultLimit: Self.defaultMLXCacheLimit
        )
        loadedModel = candidate
        loadedModelID = model.id
        loadedModelURL = modelURL
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
            shortText = "清晨的阳光轻轻落在安静的房间里。"
        case "ja":
            shortText = "朝の光が静かな部屋にやさしく差し込みました。"
        case "ko":
            shortText = "아침 햇살이 조용한 방 안으로 부드럽게 스며들었습니다."
        case "de":
            shortText = "Das Morgenlicht fiel sanft in den stillen Raum."
        case "fr":
            shortText = "La lumière du matin entrait doucement dans la pièce."
        case "es":
            shortText = "La luz de la mañana entraba suavemente en la sala."
        case "it":
            shortText = "La luce del mattino entrava dolcemente nella stanza."
        case "pt":
            shortText = "A luz da manhã entrava suavemente na sala tranquila."
        case "ru":
            shortText = "Утренний свет мягко наполнял тихую комнату."
        default:
            shortText = "Morning light settled softly across the quiet room."
        }
        if modelType.lowercased() == "fish_speech" {
            return "\(shortText) The day felt unhurried, clear, and full of small possibilities."
        }
        return shortText
    }

    private func cachedReferenceAudio(
        from url: URL,
        targetSampleRate: Double
    ) throws -> MLXArray {
        let standardized = url.standardizedFileURL
        let resourceValues = try? standardized.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let cacheKey = ReferenceAudioCacheKey(
            path: standardized.path,
            sampleRate: Int(targetSampleRate.rounded()),
            fileSize: Int64(resourceValues?.fileSize ?? -1),
            modifiedTimeInterval: resourceValues?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
        if let cached = referenceAudioCache[cacheKey] {
            if let existingIndex = referenceAudioCacheOrder.firstIndex(of: cacheKey) {
                referenceAudioCacheOrder.remove(at: existingIndex)
            }
            referenceAudioCacheOrder.append(cacheKey)
            return cached
        }
        let loaded = try loadReferenceAudio(
            from: standardized,
            targetSampleRate: targetSampleRate
        )
        referenceAudioCache[cacheKey] = loaded
        referenceAudioCacheOrder.append(cacheKey)
        if referenceAudioCacheOrder.count > Self.maxCachedReferenceAudios {
            let evicted = referenceAudioCacheOrder.removeFirst()
            referenceAudioCache.removeValue(forKey: evicted)
        }
        return loaded
    }

    private func cachedQwen3Conditioning(
        for model: Qwen3TTSModel,
        referenceAudio: MLXArray,
        transcript: String,
        language: String?
    ) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning {
        let key = Qwen3ConditioningCacheKey(
            modelID: ObjectIdentifier(model),
            audioID: ObjectIdentifier(referenceAudio),
            transcript: transcript,
            language: language ?? "auto"
        )
        if let cached = qwen3ConditioningCache[key] {
            if let existingIndex = qwen3ConditioningCacheOrder.firstIndex(of: key) {
                qwen3ConditioningCacheOrder.remove(at: existingIndex)
            }
            qwen3ConditioningCacheOrder.append(key)
            return cached
        }
        let prepared = try model.prepareReferenceConditioning(
            refAudio: referenceAudio,
            refText: transcript,
            language: language
        )
        qwen3ConditioningCache[key] = prepared
        qwen3ConditioningCacheOrder.append(key)
        if qwen3ConditioningCacheOrder.count > Self.maxCachedQwen3Conditionings {
            let evicted = qwen3ConditioningCacheOrder.removeFirst()
            qwen3ConditioningCache.removeValue(forKey: evicted)
        }
        return prepared
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
        guard count > 0 else {
            throw SynthesisError.invalidReferenceAudio
        }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: channels[0], count: count)
            }
        } else {
            var scale = 1.0 / Float(channelCount)
            mono.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                vDSP_vsmul(channels[0], 1, &scale, dstBase, 1, vDSP_Length(count))
                for channelIndex in 1..<channelCount {
                    vDSP_vsma(
                        channels[channelIndex],
                        1,
                        &scale,
                        dstBase,
                        1,
                        dstBase,
                        1,
                        vDSP_Length(count)
                    )
                }
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
        let step = Float(sourceRate / targetSampleRate)
        let maxIndex = Float(mono.count - 1)
        var positions = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var increment = step
        vDSP_vramp(&start, &increment, &positions, 1, vDSP_Length(outputCount))
        var minVal: Float = 0
        var maxVal = maxIndex
        vDSP_vclip(positions, 1, &minVal, &maxVal, &positions, 1, vDSP_Length(outputCount))
        vDSP_vlint(mono, positions, 1, &resampled, 1, vDSP_Length(outputCount), vDSP_Length(mono.count))
        return MLXArray(resampled)
    }

    private func fittingPieces(
        for chunk: SpeechChunk,
        request: SpeechRequest,
        model: SpeechGenerationModel
    ) async throws -> [SpeechChunk] {
        let modelType = request.model.modelType.lowercased()
        if modelType == "fish_drama3" {
            // Bound each Drama 3 prompt using the existing text
            // budget in UTF-8 bytes, as the reference implementation does.
            return try chunker.fittingPieces(for: chunk) { text in
                try Task.checkCancellation()
                return text.utf8.count <= 300
            }
        }
        guard let loadedTextProcessor else { return [chunk] }
        switch modelType {
        case "kokoro", "kokoro_tts":
            let language = request.language
                ?? request.voice.flatMap(
                    KokoroMultilingualProcessor.languageForVoice
                )
                ?? "en-us"
            if let caching = loadedTextProcessor as? CachingTextProcessor {
                try await caching.prepare(for: language)
            } else if let processor =
                loadedTextProcessor as? KokoroMultilingualProcessor {
                try await processor.prepare(for: language)
            }
            return try chunker.fittingPieces(for: chunk) { text in
                try Task.checkCancellation()
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
            return try chunker.fittingPieces(for: chunk) { text in
                try Task.checkCancellation()
                let processed = try loadedTextProcessor.process(
                    text: text,
                    language: request.language
                )
                return processed.count <= tokenBudget
            }
        default:
            return [chunk]
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
            synchronizeMLXAfterSuccess()
        } catch {
            synchronizeAndClearMLXCache()
            throw error
        }
    }

    private func phononEmbeddingVoice(
        _ reference: VoiceReference?, model: ModelDescriptor
    ) throws -> String? {
        guard let reference, reference.kind == .phononEmbedding else { return nil }
        guard SupportedModelTypes.areCompatible(model.modelType, "phonon") else {
            throw ServiceFailure(
                code: "voice.import_unsupported",
                message: "This voice file requires a Phonon model."
            )
        }
        try PhononVoiceFile.validate(Data(contentsOf: reference.audioURL, options: .mappedIfSafe))
        return reference.audioURL.path
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
            synchronizeMLXAfterSuccess()
            return result
        } catch {
            synchronizeAndClearMLXCache()
            throw error
        }
    }

    private func releaseLoadedModel(ifCurrent operationID: UInt64) {
        guard operationID == operationGeneration else { return }
        releaseLoadedModel()
    }

    private func releaseLoadedModel() {
        if let pocketTTS = loadedModel as? PocketTTSModel {
            PocketTTSStreamRunner.clearCaches(for: pocketTTS)
        }
        if let caching = loadedTextProcessor as? CachingTextProcessor {
            caching.clearCache()
        }
        qwen3ConditioningCache.removeAll(keepingCapacity: false)
        qwen3ConditioningCacheOrder.removeAll(keepingCapacity: false)
        referenceAudioCache.removeAll(keepingCapacity: false)
        referenceAudioCacheOrder.removeAll(keepingCapacity: false)
        guard loadedModel != nil || retainedReferenceAudio != nil else {
            loadedModelID = nil
            loadedModelURL = nil
            loadedTextProcessor = nil
            return
        }
        Stream.gpu.synchronize()
        loadedModel = nil
        loadedModelID = nil
        loadedModelURL = nil
        loadedTextProcessor = nil
        retainedReferenceAudio = nil
        Memory.clearCache()
    }

    private func synchronizeMLXAfterSuccess() {
        guard loadedModel != nil || retainedReferenceAudio != nil else { return }
        Stream.gpu.synchronize()
    }

    private func synchronizeAndClearMLXCache() {
        guard loadedModel != nil || retainedReferenceAudio != nil else { return }
        Stream.gpu.synchronize()
        Memory.clearCache()
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

    func generateDramaSamplesStream(
        text: String,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        generationParameters: GenerateParameters,
        streamingFrames: Int
    ) -> AsyncThrowingStream<[Float], Error> {
        guard let drama = model as? DramaLibraryModel else {
            return AsyncThrowingStream { $0.finish(throwing: SynthesisError.generatedNoAudio) }
        }
        return drama.generateDirectSamplesStream(
            text: text,
            refAudio: referenceAudio.value,
            refText: refText,
            generationParameters: generationParameters,
            streamingFrames: streamingFrames
        )
    }

    func generateQwen3SamplesStream(
        text: String,
        conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<[Float], Error> {
        guard model is Qwen3TTSModel else {
            return AsyncThrowingStream { $0.finish(throwing: SynthesisError.generatedNoAudio) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let qwen3 = self.model as? Qwen3TTSModel else {
                        throw SynthesisError.generatedNoAudio
                    }
                    let source = qwen3.generateStream(
                        text: text,
                        conditioning: conditioning,
                        generationParameters: generationParameters,
                        streamingInterval: streamingInterval
                    )
                    for try await event in source {
                        try Task.checkCancellation()
                        if case .audio(let array) = event {
                            let samples = array.asType(.float32).asArray(Float.self)
                            if !samples.isEmpty {
                                continuation.yield(samples)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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
