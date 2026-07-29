import Foundation
import MLXAudioTTS
import SayItCore

actor SynthesisActor: SpeechSynthesizing {
    typealias ModelURLProvider = @Sendable (ModelID) async -> URL?

    private let modelURLProvider: ModelURLProvider
    private let chunker: TextChunker
    private var loadedModel: SpeechGenerationModel?
    private var loadedModelID: ModelID?
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
        }

        if loadedModel == nil {
            continuation.yield(.loadingModel(request.model.id))
            guard let modelURL = await modelURLProvider(request.model.id) else {
                throw SynthesisError.modelNotInstalled
            }
            loadedModel = try await TTS.loadModel(
                modelRepo: modelURL.path,
                modelType: request.model.modelType
            )
            loadedModelID = request.model.id
            continuation.yield(.modelLoaded(request.model.id))
        }

        guard let loadedModel else {
            throw SynthesisError.modelNotInstalled
        }

        let chunks = chunker.chunks(for: request.cleanedText.text)
        var generatedSamples = 0
        for chunk in chunks {
            try Task.checkCancellation()
            continuation.yield(
                .chunkStarted(
                    index: chunk.id,
                    total: chunks.count,
                    textPreview: String(chunk.text.prefix(120))
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

            if chunk.startsParagraph, generatedSamples > 0 {
                let silenceCount = Int(Double(loadedModel.sampleRate) * 0.18)
                let silence = AudioChunk(
                    requestID: request.id,
                    index: chunk.id,
                    samples: Array(repeating: 0, count: silenceCount),
                    sampleRate: Double(loadedModel.sampleRate),
                    startsParagraph: true
                )
                continuation.yield(.audio(silence))
                generatedSamples += silenceCount
            }

            for try await samples in stream {
                try Task.checkCancellation()
                guard !samples.isEmpty else { continue }
                let audio = AudioChunk(
                    requestID: request.id,
                    index: chunk.id,
                    samples: samples,
                    sampleRate: Double(loadedModel.sampleRate),
                    startsParagraph: chunk.startsParagraph
                )
                continuation.yield(.audio(audio))
                chunkSamples += samples.count
                generatedSamples += samples.count
            }

            let duration = start.duration(to: .now)
            let generationDuration = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            continuation.yield(
                .metrics(
                    SynthesisMetrics(
                        chunkIndex: chunk.id,
                        generationDuration: generationDuration,
                        audioDuration: Double(chunkSamples)
                            / Double(loadedModel.sampleRate)
                    )
                )
            )
        }

        guard generatedSamples > 0 else {
            throw SynthesisError.generatedNoAudio
        }
        continuation.yield(.completed)
        continuation.finish()
        currentTask = nil
        scheduleIdleUnload()
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
