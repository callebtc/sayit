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
    private static let fastStartFirstChunkTarget = 60
    private static let fastStartFirstChunkThreshold = 90
    private static let dramaFastStartFirstChunkTarget = 60
    private static let dramaFastStartFirstChunkThreshold = 95
    private static let qwenFastStartFirstChunkTarget = 60
    private static let qwenFastStartFirstChunkThreshold = 95
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

    private struct Qwen3ConditioningCacheEntry {
        /// Retains the backing MLXArray so its `ObjectIdentifier` cannot be
        /// recycled while the entry remains in the LRU cache.
        let referenceAudio: MLXArray
        let conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning
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
    private var qwen3ConditioningCache: [Qwen3ConditioningCacheKey: Qwen3ConditioningCacheEntry] = [:]
    private var qwen3ConditioningCacheOrder: [Qwen3ConditioningCacheKey] = []
    private var operationGeneration: UInt64 = 0
    private var requestArrivalOrder: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var idleUnloadTask: Task<Void, Never>?
    private var cancelPreloadWarmupRequested = false

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
        guard !Task.isCancelled else {
            return cancelledStream()
        }
        requestArrivalOrder &+= 1
        let arrivalOrder = requestArrivalOrder
        if let active = activeOperation, active.preloadingModelID == request.model.id {
            cancelPreloadWarmupRequested = true
            if loadedModelID != request.model.id || loadedModel == nil {
                // Weights are still loading from disk: let weight loading finish
                // instead of discarding partial work, while skipping opportunistic warmup.
                await waitForOperationToFinish(active)
                guard !Task.isCancelled, arrivalOrder == requestArrivalOrder else {
                    return cancelledStream()
                }
            }
        }

        let (operationID, previousOperation) = reserveOperation()
        await waitForOperationToFinish(previousOperation)
        guard !Task.isCancelled, operationID == operationGeneration else {
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
        guard !Task.isCancelled, activeOperation == nil else { return }
        cancelPreloadWarmupRequested = false
        let (operationID, _) = reserveOperation()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.operationGate.perform {
                    try await self.performPreloadAndQuiesce(
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

    func waitForActiveOperation() async {
        await waitForOperationToFinish(activeOperation)
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

    private func performPreloadAndQuiesce(
        _ model: ModelDescriptor,
        voice: String?,
        voiceReference: VoiceReference?,
        language: String?,
        operationID: UInt64
    ) async throws {
        do {
            try await performPreload(
                model,
                voice: voice,
                voiceReference: voiceReference,
                language: language,
                operationID: operationID
            )
            synchronizeMLXAfterSuccess()
        } catch {
            synchronizeAndClearMLXCache()
            throw error
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
        guard !cancelPreloadWarmupRequested, let loadedModel else { return }

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
                if let kokoro = loadedModel as? KokoroModel {
                    let warmVoice = voice ?? model.defaultVoice ?? "af_heart"
                    _ = try? kokoro.loadVoice(named: warmVoice)
                    try checkOperation(operationID)
                    _ = try? await SerializedSpeechModel(kokoro).generateSamples(
                        text: "Hi.",
                        voice: warmVoice,
                        referenceAudio: SerializedMLXArray(nil),
                        refText: nil,
                        language: targetLanguage,
                        generationParameters: kokoro.defaultGenerationParameters
                    )
                }
            } else if modelType == "kitten" || modelType == "kitten_tts" {
                try? await cachingProcessor.prepare()
            }
        } else if let drama = loadedModel as? DramaLibraryModel {
            if let voiceReference,
               voiceReference.kind == .audio,
               let transcript = voiceReference.transcript,
               !transcript.isEmpty,
               let referenceAudio = try? cachedReferenceAudio(
                   from: voiceReference.audioURL,
                   targetSampleRate: Double(loadedModel.sampleRate)
               ) {
                retainedReferenceAudio = referenceAudio
                try? await SerializedSpeechModel(drama).warmDramaVoice(
                    referenceAudio: SerializedMLXArray(referenceAudio),
                    refText: transcript
                )
            } else {
                try? await SerializedSpeechModel(drama).warmDramaVoice(
                    referenceAudio: SerializedMLXArray(nil),
                    refText: nil
                )
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
        try Task.checkCancellation()
        requestArrivalOrder &+= 1
        let arrivalOrder = requestArrivalOrder
        if let active = activeOperation, active.preloadingModelID == model.id {
            cancelPreloadWarmupRequested = true
            if loadedModelID != model.id || loadedModel == nil {
                await waitForOperationToFinish(active)
                try Task.checkCancellation()
                guard arrivalOrder == requestArrivalOrder else {
                    throw CancellationError()
                }
            }
        }

        let (operationID, previousOperation) = reserveOperation()
        await waitForOperationToFinish(previousOperation)
        try Task.checkCancellation()
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
           let thresholds = Self.fastStartThresholds(forModelType: modelTypeLower) {
            let split = chunker.splitFirstChunkForFastStart(
                chunks[0],
                targetCharacterCount: thresholds.target,
                minimumLengthToSplit: thresholds.minimumLength
            )
            if split.count > 1 {
                chunks.replaceSubrange(0...0, with: split)
            }
        }

        // Fit chunk 0 before deciding whether automaticStable has multiple
        // model calls: a single >300-byte Drama sentence can split into multiple
        // fitted pieces that must all share the same voice.
        var prefittedFirstChunk = false
        if !chunks.isEmpty,
           request.voiceMode == .automaticStable,
           request.model.capabilities.supportsRandomVoiceSampling,
           referenceAudio == nil {
            let fittedFirst = try await fittingPieces(
                for: chunks[0],
                request: request,
                model: loadedModel
            )
            chunks.replaceSubrange(0...0, with: fittedFirst)
            prefittedFirstChunk = true
        }

        // For `automaticStable` multi-chunk requests, self-anchor on chunk 0
        // whenever chunk 0 is a natural sentence (>= 36 chars): chunk 0 streams
        // immediately with zero throwaway anchor synthesis, and chunks 1..N clone
        // chunk 0's exact voice. Single-chunk requests need no anchor at all.
        var captureChunk0AsSelfAnchor = try await configureAutomaticVoiceAnchor(
            for: request,
            chunks: chunks,
            model: loadedModel,
            operationID: operationID,
            continuation: continuation,
            referenceAudio: &referenceAudio,
            referenceText: &referenceText
        )

        recordTiming(.voicePreparation, since: voiceStarted)
        var conditioner = try PCMStreamConditioner(
            sampleRate: Double(loadedModel.sampleRate)
        )
        let streamingInterval: Double = request.model.playbackMode == .progressive ? 0.32 : 0.8
        let emitsAdaptiveProgress = loadedModel is DramaLibraryModel
            || request.model.playbackMode == .adaptive
        var chunkCursor = 0
        var completedChunkCount = 0
        var generatedSamples = 0
        var ephemeralQwen3Conditioning: (
            audioID: ObjectIdentifier,
            transcript: String,
            conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning
        )?
        while chunkCursor < chunks.count {
            try Task.checkCancellation()
            if chunkCursor > 0, chunkDelay > 0 {
                try await Task.sleep(for: .seconds(chunkDelay))
            }
            // Fit only the next logical chunk. Phonemizing a whole article here
            // would delay first audio even though the model consumes one chunk.
            if !(prefittedFirstChunk && chunkCursor == 0) {
                let pieces = try await fittingPieces(
                    for: chunks[chunkCursor], request: request, model: loadedModel
                )
                chunks.replaceSubrange(chunkCursor...chunkCursor, with: pieces)
            }
            prefittedFirstChunk = false
            let chunk = chunks[chunkCursor]
            continuation.yield(
                .chunkStarted(
                    index: completedChunkCount,
                    chunk: chunk
                )
            )

            let start = ContinuousClock.now
            var chunkSamples = 0
            var selfAnchorSamples: [Float] = []
            let capturingSelfAnchorThisChunk = captureChunk0AsSelfAnchor && chunkCursor == 0
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
                    if capturingSelfAnchorThisChunk {
                        selfAnchorSamples.append(contentsOf: samples)
                    }

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
                    // Start tight on chunk 0 (10 frames ≈ 0.46 s) and stay tight
                    // while total buffered audio is still short (< 5 s, e.g. after
                    // a short 1-sentence opening paragraph) so chunk 1 delivers
                    // before playback drains, then ramp to 24 frames (≈ 1.11 s),
                    // safely below DramaTTS's 2.0 s QuietGate dead-air threshold.
                    let dramaStreamingFrames: Int
                    if chunkCursor == 0 {
                        dramaStreamingFrames = 10
                    } else if generatedSamples < loadedModel.sampleRate * 5 {
                        dramaStreamingFrames = 12
                    } else {
                        dramaStreamingFrames = DramaLibraryModel.maximumStreamingFrames
                    }
                    let managed = SerializedSpeechModel(drama)
                        .makeManagedDramaSamplesStream(
                            text: chunk.text,
                            referenceAudio: SerializedMLXArray(
                                usesReference ? referenceAudio : nil
                            ),
                            refText: usesReference ? referenceText : nil,
                            generationParameters: parameters,
                            streamingFrames: dramaStreamingFrames
                        )
                    do {
                        for try await samples in managed.stream {
                            try checkOperation(operationID)
                            try emit(samples)
                        }
                        await managed.waitForCompletion()
                    } catch {
                        await managed.cancelAndWait()
                        throw error
                    }
                } else if let pocketTTS = loadedModel as? PocketTTSModel,
                          let modelURL = loadedModelURL {
                    let managed = PocketTTSStreamRunner.makeManagedSamplesStream(
                        model: pocketTTS,
                        modelFolder: modelURL,
                        text: chunk.text,
                        voice: voiceArgument,
                        referenceAudio: usesReference ? referenceAudio : nil,
                        generationParameters: parameters,
                        streamingInterval: streamingInterval
                    )
                    do {
                        for try await samples in managed.stream {
                            try checkOperation(operationID)
                            try emit(samples)
                        }
                        await managed.waitForCompletion()
                    } catch {
                        await managed.cancelAndWait()
                        throw error
                    }
                } else if let qwen3 = loadedModel as? Qwen3TTSModel,
                          usesReference,
                          let referenceAudio,
                          let referenceText,
                          !referenceText.isEmpty {
                    let conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning
                    if Self.shouldCacheQwen3Conditioning(voiceMode: request.voiceMode) {
                        conditioning = try cachedQwen3Conditioning(
                            for: qwen3,
                            referenceAudio: referenceAudio,
                            transcript: referenceText,
                            language: request.language
                        )
                    } else if let cached = ephemeralQwen3Conditioning,
                              cached.audioID == ObjectIdentifier(referenceAudio),
                              cached.transcript == referenceText {
                        conditioning = cached.conditioning
                    } else {
                        let prepared = try qwen3.prepareReferenceConditioning(
                            refAudio: referenceAudio,
                            refText: referenceText,
                            language: request.language
                        )
                        ephemeralQwen3Conditioning = (
                            ObjectIdentifier(referenceAudio),
                            referenceText,
                            prepared
                        )
                        conditioning = prepared
                    }
                    let qwenStreamingInterval = chunkCursor == 0 ? 0.32 : 2.0
                    let managed = SerializedSpeechModel(qwen3)
                        .makeManagedQwen3SamplesStream(
                            text: chunk.text,
                            conditioning: conditioning,
                            generationParameters: parameters,
                            streamingInterval: qwenStreamingInterval
                        )
                    do {
                        for try await samples in managed.stream {
                            try checkOperation(operationID)
                            try emit(samples)
                        }
                        await managed.waitForCompletion()
                    } catch {
                        await managed.cancelAndWait()
                        throw error
                    }
                } else {
                    let effectiveInterval = loadedModel is Qwen3TTSModel
                        ? (chunkCursor == 0 ? 0.32 : 2.0)
                        : streamingInterval
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
                        streamingInterval: effectiveInterval
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
                // If an initially single-chunk automaticStable request split
                // into multiple pieces on retry, re-enable voice anchoring so
                // replacement pieces share one consistent voice.
                if chunkCursor == 0 {
                    captureChunk0AsSelfAnchor = try await configureAutomaticVoiceAnchor(
                        for: request,
                        chunks: chunks,
                        model: loadedModel,
                        operationID: operationID,
                        continuation: continuation,
                        referenceAudio: &referenceAudio,
                        referenceText: &referenceText
                    )
                }
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
            if capturingSelfAnchorThisChunk {
                captureChunk0AsSelfAnchor = false
                if chunkCursor + 1 < chunks.count {
                    let minAnchorFrames = Int(Double(loadedModel.sampleRate) * 0.25)
                    let maxAnchorFrames = Int(Double(loadedModel.sampleRate) * 25.0)
                    if selfAnchorSamples.count >= minAnchorFrames,
                       selfAnchorSamples.count <= maxAnchorFrames {
                        referenceAudio = MLXArray(selfAnchorSamples)
                        retainedReferenceAudio = referenceAudio
                        referenceText = chunk.text
                    } else {
                        let anchor = try await synthesizeArticleVoiceAnchor(
                            for: request,
                            model: loadedModel,
                            operationID: operationID,
                            continuation: continuation
                        )
                        referenceAudio = MLXArray(anchor.samples)
                        retainedReferenceAudio = referenceAudio
                        referenceText = anchor.text
                    }
                }
                selfAnchorSamples.removeAll(keepingCapacity: false)
            }

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

    enum AutomaticStableAnchorAction: Equatable {
        case none
        case selfAnchorFirstChunk
        case synthesizeAnchorUpfront
    }

    static let selfAnchorMinimumCharacterCount = 36

    static func automaticStableAnchorAction(
        voiceMode: VoiceSynthesisMode,
        supportsRandomVoiceSampling: Bool,
        hasReferenceAudio: Bool,
        chunkCount: Int,
        firstChunkLength: Int
    ) -> AutomaticStableAnchorAction {
        guard voiceMode == .automaticStable,
              supportsRandomVoiceSampling,
              !hasReferenceAudio,
              chunkCount > 1 else {
            return .none
        }
        return firstChunkLength >= selfAnchorMinimumCharacterCount
            ? .selfAnchorFirstChunk
            : .synthesizeAnchorUpfront
    }

    private func configureAutomaticVoiceAnchor(
        for request: SpeechRequest,
        chunks: [SpeechChunk],
        model: SpeechGenerationModel,
        operationID: UInt64,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation,
        referenceAudio: inout MLXArray?,
        referenceText: inout String?
    ) async throws -> Bool {
        let action = Self.automaticStableAnchorAction(
            voiceMode: request.voiceMode,
            supportsRandomVoiceSampling: request.model.capabilities.supportsRandomVoiceSampling,
            hasReferenceAudio: referenceAudio != nil,
            chunkCount: chunks.count,
            firstChunkLength: chunks.first?.text.count ?? 0
        )
        switch action {
        case .none:
            return false
        case .selfAnchorFirstChunk:
            return true
        case .synthesizeAnchorUpfront:
            let anchor = try await synthesizeArticleVoiceAnchor(
                for: request,
                model: model,
                operationID: operationID,
                continuation: continuation
            )
            referenceAudio = MLXArray(anchor.samples)
            retainedReferenceAudio = referenceAudio
            referenceText = anchor.text
            return false
        }
    }

    private static func fastStartThresholds(
        forModelType modelType: String
    ) -> (target: Int, minimumLength: Int)? {
        switch modelType {
        case "kokoro", "kokoro_tts", "kitten", "kitten_tts", "omnivoice", "soprano", "soprano_tts":
            (fastStartFirstChunkTarget, fastStartFirstChunkThreshold)
        case "fish_drama3":
            (dramaFastStartFirstChunkTarget, dramaFastStartFirstChunkThreshold)
        case "qwen3_tts":
            (qwenFastStartFirstChunkTarget, qwenFastStartFirstChunkThreshold)
        default:
            nil
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
        var candidate: SpeechGenerationModel?
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
            candidate = nil
            Stream.gpu.synchronize()
            Memory.clearCache()
            throw error
        }
        do {
            try checkOperation(operationID)
        } catch {
            Stream.gpu.synchronize()
            candidate = nil
            Memory.clearCache()
            throw error
        }
        guard let resolvedCandidate = candidate else {
            throw SynthesisError.modelNotInstalled
        }
        Memory.cacheLimit = MLXCachePolicy.cacheLimit(
            forModelType: model.modelType,
            defaultLimit: Self.defaultMLXCacheLimit
        )
        loadedModel = resolvedCandidate
        loadedModelID = model.id
        loadedModelURL = modelURL
        loadedTextProcessor = textProcessor
    }

    private func synthesizeArticleVoiceAnchor(
        for request: SpeechRequest,
        model: SpeechGenerationModel,
        operationID: UInt64,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws -> (samples: [Float], text: String) {
        continuation.yield(.creatingArticleVoice)
        let anchorText = articleVoiceAnchor(
            language: request.language,
            modelType: request.model.modelType
        )
        var parameters = model.defaultGenerationParameters
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
        let anchorSamples = try await SerializedSpeechModel(model)
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
        return (anchorSamples, anchorText)
    }

    private func articleVoiceAnchor(
        language: String?,
        modelType: String
    ) -> String {
        let normalized = language?.lowercased() ?? "en"
        let shortText: String
        switch normalized.split(separator: "-").first {
        case "zh":
            shortText = "清晨的阳光落在安静的房间里。"
        case "ja":
            shortText = "朝の光が静かな部屋に差し込みました。"
        case "ko":
            shortText = "아침 햇살이 조용한 방에 스며들었습니다."
        case "de":
            shortText = "Klares Morgenlicht füllte den Raum."
        case "fr":
            shortText = "La lumière du matin emplit la pièce."
        case "es":
            shortText = "La luz de la mañana llenó la sala."
        case "it":
            shortText = "La luce del mattino riempì la stanza."
        case "pt":
            shortText = "A luz da manhã encheu a sala."
        case "ru":
            shortText = "Утренний свет наполнил тихую комнату."
        default:
            shortText = "Clear morning light filled the room."
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

    static func shouldCacheQwen3Conditioning(
        voiceMode: VoiceSynthesisMode
    ) -> Bool {
        voiceMode == .savedProfile
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
            return cached.conditioning
        }
        let prepared = try model.prepareReferenceConditioning(
            refAudio: referenceAudio,
            refText: transcript,
            language: language
        )
        qwen3ConditioningCache[key] = Qwen3ConditioningCacheEntry(
            referenceAudio: referenceAudio,
            conditioning: prepared
        )
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
        return MLXArray(
            Self.resampleMono(
                mono,
                from: sourceRate,
                to: targetSampleRate
            )
        )
    }

    /// Linearly resamples mono PCM using `vDSP_vlint` with a trailing duplicate
    /// sentinel sample so `vDSP_vlint`'s documented `A[floor(b) + 1]` access is
    /// always strictly in bounds even when `b == mono.count - 1`.
    static func resampleMono(
        _ mono: [Float],
        from sourceRate: Double,
        to targetSampleRate: Double
    ) -> [Float] {
        guard !mono.isEmpty else { return [] }
        if abs(sourceRate - targetSampleRate) < 1 {
            return mono
        }
        let outputCount = max(
            Int(Double(mono.count) * targetSampleRate / sourceRate),
            1
        )
        if mono.count == 1 {
            return [Float](repeating: mono[0], count: outputCount)
        }
        var padded = mono
        padded.append(mono[mono.count - 1])
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
        vDSP_vlint(padded, positions, 1, &resampled, 1, vDSP_Length(outputCount), vDSP_Length(padded.count))
        return resampled
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
        if case .generationLimit = error as? Drama3Error {
            return true
        }
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

    func makeManagedDramaSamplesStream(
        text: String,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        generationParameters: GenerateParameters,
        streamingFrames: Int
    ) -> ManagedSampleStream {
        guard let drama = model as? DramaLibraryModel else {
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
            continuation.finish(throwing: SynthesisError.generatedNoAudio)
            return ManagedSampleStream(stream: stream, producer: Task {})
        }
        return drama.makeManagedDirectSamplesStream(
            text: text,
            refAudio: referenceAudio.value,
            refText: refText,
            generationParameters: generationParameters,
            streamingFrames: streamingFrames
        )
    }

    func warmDramaVoice(
        referenceAudio: SerializedMLXArray,
        refText: String?
    ) async throws {
        guard let drama = model as? DramaLibraryModel else { return }
        try await drama.warmVoice(refAudio: referenceAudio.value, refText: refText)
    }

    func makeManagedQwen3SamplesStream(
        text: String,
        conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> ManagedSampleStream {
        guard model is Qwen3TTSModel else {
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
            continuation.finish(throwing: SynthesisError.generatedNoAudio)
            return ManagedSampleStream(stream: stream, producer: Task {})
        }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
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
        return ManagedSampleStream(stream: stream, producer: task)
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

/// Pairs an `AsyncThrowingStream` with its producer `Task` so cancellation or
/// early exit always awaits producer completion before `SynthesisOperationGate`
/// releases the non-Sendable MLX model to the next operation.
struct ManagedSampleStream: Sendable {
    let stream: AsyncThrowingStream<[Float], Error>
    private let producer: Task<Void, Never>

    init(
        stream: AsyncThrowingStream<[Float], Error>,
        producer: Task<Void, Never>
    ) {
        self.stream = stream
        self.producer = producer
    }

    func waitForCompletion() async {
        await producer.value
    }

    func cancelAndWait() async {
        producer.cancel()
        await producer.value
    }

    func drain(
        _ consume: ([Float]) throws -> Void
    ) async throws {
        do {
            for try await samples in stream {
                try consume(samples)
            }
            await waitForCompletion()
        } catch {
            await cancelAndWait()
            throw error
        }
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
