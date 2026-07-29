import Foundation

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

    private func run(
        _ request: SpeechRequest,
        continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
    ) async throws {
        if loadedModelID != request.model.id {
            loadedModel = nil
            loadedModelID = nil
            loadedTextProcessor = nil
        }

        if loadedModel == nil {
            continuation.yield(.loadingModel(request.model.id))
            guard let modelURL = await modelURLProvider(request.model.id) else {
                throw SynthesisError.modelNotInstalled
            }
            let textProcessor = makeTextProcessor(for: request.model)
            loadedModel = try await TTS.loadModel(
                modelRepo: modelURL.path,
                modelType: request.model.modelType,
                textProcessor: textProcessor
            )
            loadedModelID = request.model.id
            loadedTextProcessor = textProcessor
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
            let voiceArgument = request.model.capabilities.voiceDescription
                ? request.voiceDescription
                : request.voice
            let stream = loadedModel.generateSamplesStream(
                text: chunk.text,
                voice: voiceArgument,
                refAudio: nil,
                refText: nil,
                language: request.language,
                streamingInterval: request.model.playbackMode == .progressive ? 0.32 : 2
            )

            do {
                for try await samples in stream {
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { continue }

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
