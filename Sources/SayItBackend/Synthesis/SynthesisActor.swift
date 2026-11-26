import Foundation
import SayItCore

actor SynthesisActor: BackendSpeechSynthesizing {
    typealias ModelURLProvider = @Sendable (ModelID) async -> URL?

    // Orpheus is capped at 1,200 audio tokens, roughly 15 seconds.
    // Short inputs let each request reach EOS instead of truncating mid-block.
    static let orpheusChunker = TextChunker(
        targetCharacterCount: 90,
        hardCharacterLimit: 120
    )
    private static let operationGate = SynthesisOperationGate()

    private struct ActiveOperation: Sendable {
        let id: UInt64
        let cancel: @Sendable () -> Void
        let completion: Task<Void, Never>
    }

    private let modelURLProvider: ModelURLProvider
    private let loader: any SpeechModelLoading
    private let clock: any SynthesisClock
    private var chunker: TextChunker
    private var chunkDelay: Double = 0
    private var paragraphPause: Double = 0.18
    private var idleUnloadDelay: Double = 600
    private var loadedSession: (any SpeechModelSession)?
    private var loadedModelID: ModelID?
    private var operationGeneration: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        modelURLProvider: @escaping ModelURLProvider,
        chunker: TextChunker = TextChunker(),
        loader: any SpeechModelLoading = LiveSpeechModelLoader(),
        clock: any SynthesisClock = LiveSynthesisClock()
    ) {
        self.modelURLProvider = modelURLProvider
        self.chunker = chunker
        self.loader = loader
        self.clock = clock
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
                await self.releaseLoadedSession(ifCurrent: operationID)
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
            try await self.loader.prepareDependencies(for: model)
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
        guard let loadedSession else {
            throw SynthesisError.modelNotInstalled
        }
        var generationReference: SpeechModelReference?
        if let reference {
            let samples = try ReferenceAudioDecoder.decodeMonoSamples(
                from: reference.audioURL,
                targetSampleRate: loadedSession.sampleRate
            )
            generationReference = SpeechModelReference(
                samples: samples,
                transcript: reference.transcript
            )
        }
        let samples: [Float]
        do {
            samples = try await loadedSession.generateSamples(
                text: text,
                voice: nil,
                reference: generationReference,
                language: language,
                tuning: tuning,
                seed: seed,
                allowTuningSelectedGeneration: true
            )
        } catch {
            throw Self.surfacedGenerationError(error)
        }
        try checkOperation(operationID)
        guard !samples.isEmpty else {
            throw SynthesisError.generatedNoAudio
        }
        return GeneratedVoiceSample(
            samples: samples,
            sampleRate: loadedSession.sampleRate
        )
    }

    private func run(
        _ request: SpeechRequest,
        operationID: UInt64,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws {
        try checkOperation(operationID)
        if loadedModelID != request.model.id || loadedSession == nil {
            continuation.yield(.loadingModel(request.model.id))
            try await ensureModelLoaded(
                request.model,
                operationID: operationID
            )
            try checkOperation(operationID)
            continuation.yield(.modelLoaded(request.model.id))
        }

        guard let loadedSession else {
            throw SynthesisError.modelNotInstalled
        }
        try loadedSession.applySpeakingPace(request.speakingPace)

        var generationReference = try request.voiceReference.map {
            reference in
            SpeechModelReference(
                samples: try ReferenceAudioDecoder.decodeMonoSamples(
                    from: reference.audioURL,
                    targetSampleRate: loadedSession.sampleRate
                ),
                transcript: reference.transcript
            )
        }
        if request.voiceMode == .automaticStable,
           request.model.capabilities.supportsRandomVoiceSampling {
            continuation.yield(.creatingArticleVoice)
            let anchorText = articleVoiceAnchor(
                language: request.language,
                modelType: request.model.modelType
            )
            let anchorVoice = request.model.capabilities.voiceDescription
                ? request.voiceDescription
                : nil
            let anchorSamples: [Float]
            do {
                anchorSamples = try await loadedSession.generateSamples(
                    text: anchorText,
                    voice: anchorVoice,
                    reference: nil,
                    language: request.language,
                    tuning: request.voiceTuning,
                    seed: nil,
                    allowTuningSelectedGeneration: false
                )
            } catch {
                throw Self.surfacedGenerationError(error)
            }
            try checkOperation(operationID)
            guard !anchorSamples.isEmpty else {
                throw SynthesisError.generatedNoAudio
            }
            generationReference = SpeechModelReference(
                samples: anchorSamples,
                transcript: anchorText
            )
        }

        let usesShortChunks = ["orpheus", "orpheus_tts"].contains(request.model.modelType.lowercased())
        var chunks = try (usesShortChunks ? Self.orpheusChunker : chunker).chunks(
            for: request.cleanedText.text,
            separatesParagraphs: usesShortChunks || request.voiceMode == .randomPerParagraph,
            checkingCancellation: Task.checkCancellation
        )
        var conditioner = try PCMStreamConditioner(
            sampleRate: loadedSession.sampleRate
        )
        var chunkCursor = 0
        var completedChunkCount = 0
        var generatedSamples = 0
        while chunkCursor < chunks.count {
            try Task.checkCancellation()
            if chunkCursor > 0, chunkDelay > 0 {
                try await clock.sleep(for: .seconds(chunkDelay))
            }
            // Fit only the next logical chunk. Phonemizing a whole article here
            // would delay first audio even though the model consumes one chunk.
            let pieces = try await loadedSession.fittingPieces(
                for: chunks[chunkCursor],
                language: request.language,
                voice: request.voice,
                chunker: chunker
            )
            chunks.replaceSubrange(chunkCursor...chunkCursor, with: pieces)
            let chunk = chunks[chunkCursor]
            continuation.yield(
                .chunkStarted(
                    index: completedChunkCount,
                    chunk: chunk
                )
            )

            let start = clock.now
            var chunkSamples = 0
            let conditionerBeforeChunk = conditioner
            let usesReference = generationReference != nil
                && request.voiceMode != .randomPerParagraph
            let voiceArgument = usesReference
                ? nil
                : request.model.capabilities.voiceDescription
                    ? request.voiceDescription
                    : request.voice
            do {
                func emit(_ samples: [Float]) throws {
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { return }

                    let pauseFrameCount = chunk.startsParagraph
                        && generatedSamples > 0
                        && chunkSamples == 0
                        ? Int(loadedSession.sampleRate * paragraphPause)
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
                        sampleRate: loadedSession.sampleRate,
                        startsParagraph: chunk.startsParagraph,
                        speechStartOffset: Double(speechStartFrames)
                            / loadedSession.sampleRate
                    )
                    continuation.yield(.audio(audio))
                    chunkSamples += conditioned.count
                    generatedSamples += conditioned.count
                }

                let stream = loadedSession.generateSamplesStream(
                    text: chunk.text,
                    voice: voiceArgument,
                    reference: usesReference ? generationReference : nil,
                    language: request.language,
                    tuning: request.voiceTuning,
                    seed: nil
                )
                for try await samples in stream {
                    try checkOperation(operationID)
                    try emit(samples)
                }
            } catch {
                let replacements = chunker.subchunks(of: chunk)
                guard chunkSamples == 0,
                      error is SpeechModelInputTooLongError,
                      replacements.count > 1 else {
                    throw Self.surfacedGenerationError(error)
                }
                conditioner = conditionerBeforeChunk
                chunks.replaceSubrange(
                    chunkCursor...chunkCursor,
                    with: replacements
                )
                continue
            }

            if chunkCursor == chunks.count - 1 {
                let tail = conditioner.finish()
                if !tail.isEmpty {
                    continuation.yield(
                        .audio(
                            AudioChunk(
                                requestID: request.id,
                                index: completedChunkCount,
                                samples: tail,
                                sampleRate: loadedSession.sampleRate,
                                startsParagraph: chunk.startsParagraph
                            )
                        )
                    )
                    chunkSamples += tail.count
                    generatedSamples += tail.count
                }
            }

            let duration = start.duration(to: clock.now)
            let generationDuration = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            continuation.yield(
                .metrics(
                    SynthesisMetrics(
                        chunkIndex: completedChunkCount,
                        generationDuration: generationDuration,
                        audioDuration: Double(chunkSamples)
                            / loadedSession.sampleRate,
                        trailingAudioDuration: Double(conditioner.retainedFrameCount)
                            / loadedSession.sampleRate
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

    private func ensureModelLoaded(
        _ model: ModelDescriptor,
        operationID: UInt64
    ) async throws {
        try checkOperation(operationID)
        if loadedModelID != model.id {
            releaseLoadedSession()
        }
        guard loadedSession == nil else { return }
        let modelURL = await modelURLProvider(model.id)
        try checkOperation(operationID)
        guard let modelURL else {
            throw SynthesisError.modelNotInstalled
        }
        let candidate = try await loader.load(
            model: model,
            directory: modelURL
        )
        do {
            try checkOperation(operationID)
        } catch {
            candidate.shutdown()
            throw error
        }
        loadedSession = candidate
        loadedModelID = model.id
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
            quiesceSessionIfLoaded()
        } catch {
            quiesceSessionIfLoaded()
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
            quiesceSessionIfLoaded()
            return result
        } catch {
            quiesceSessionIfLoaded()
            throw error
        }
    }

    private func releaseLoadedSession(ifCurrent operationID: UInt64) {
        guard operationID == operationGeneration else { return }
        releaseLoadedSession()
    }

    private func releaseLoadedSession() {
        loadedSession?.shutdown()
        loadedSession = nil
        loadedModelID = nil
    }

    private func quiesceSessionIfLoaded() {
        loadedSession?.quiesce()
    }

    /// The input-too-long marker only gates subchunk retry; everywhere a
    /// generation failure leaves the actor, the original error surfaces.
    private static func surfacedGenerationError(_ error: Error) -> Error {
        (error as? SpeechModelInputTooLongError)?.underlyingError ?? error
    }

    private func scheduleIdleUnload(for operationID: UInt64) {
        idleUnloadTask?.cancel()
        guard idleUnloadDelay > 0 else { return }
        let delay = idleUnloadDelay
        let clock = self.clock
        idleUnloadTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(delay))
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
