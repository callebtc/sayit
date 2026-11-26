import DramaTTS
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import MLXNN
import SpeechSynthesizer

/// Bridges the pinned native DramaTTS engine to Say It's serialized synthesis pipeline.
/// The engine reads the existing snapshot and retains its voice/prompt cache in memory.
final class DramaLibraryModel: Module, SpeechGenerationModel, @unchecked Sendable {
    /// Keep streaming decode windows safely below DramaTTS's 2.0 s QuietGate
    /// dead-air threshold (`24 * 2048 / 44100 ≈ 1.11 s`) so silence detection
    /// always observes at least two pieces before rewinding and chunk-boundary
    /// handoffs stay responsive.
    static let maximumStreamingFrames = 24

    /// Minimum mean-square energy for a piece to count as voiced speech rather
    /// than dead-air hiss (-42 dBFS, above DramaTTS's -45 dBFS silence floor).
    private static let minimumVoicedPower: Double = 6.31e-5

    let sampleRate = 44_100
    private let engine: DramaEngine
    private let referenceCacheLock = NSLock()
    private var cachedReferenceKey: (audioID: ObjectIdentifier, transcript: String)?
    private var cachedReferenceAudio: MLXArray?
    private var cachedReferences: [DramaReference]?

    static func clampedStreamingFrames(_ requested: Int) -> Int {
        min(max(1, requested), maximumStreamingFrames)
    }

    static func pieceContainsVoicedAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        return (sumSquares / Double(samples.count)) > minimumVoicedPower
    }

    static func shouldAbortForReport(
        cappedChunks: Int,
        silencedChunks: Int,
        emittedVoicedAudio: Bool
    ) -> Bool {
        // DramaPipeline already trims trailing dead air after bounded rewinds and
        // retains finite speech up to the frame cap. Fail (allowing SynthesisActor
        // to sub-split and retry) whenever a chunk hit a limit without emitting
        // real voiced speech — including when QuietGate emitted only its 0.5 s
        // dead-air tail.
        (cappedChunks > 0 || silencedChunks > 0) && !emittedVoicedAudio
    }

    private init(engine: DramaEngine) {
        self.engine = engine
        super.init()
    }

    static func fromDirectory(_ directory: URL) async throws -> DramaLibraryModel {
        // Model installation already records acceptance of the Fish Audio licence.
        let engine = try DramaEngine(modelDirectory: directory, licence: DramaLicence.version,
                                     bufferCacheLimit: nil)
        try await engine.prepare(onProgress: nil)
        try Task.checkCancellation()
        return DramaLibraryModel(engine: engine)
    }

    var defaultGenerationParameters: GenerateParameters {
        GenerateParameters(maxTokens: 1024, temperature: 1, topP: 0.9, topK: 30)
    }

    private func inputs(
        _ refAudio: MLXArray?,
        _ refText: String?,
        _ p: GenerateParameters,
        streamingFrames: Int = 16
    ) throws -> (references: [DramaReference], settings: DramaSettings) {
        guard p.temperature.isFinite, (0...2).contains(p.temperature),
              p.topP.isFinite, p.topP > 0, p.topP <= 1, p.topK > 0 else {
            throw Drama3Error.invalidInput("Invalid Drama 3 sampling settings.")
        }
        var references: [DramaReference] = []
        if let refAudio {
            guard let refText, !refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  refAudio.size > 0, refAudio.size <= sampleRate * 30 else {
                throw Drama3Error.invalidInput("Use a voice reference of at most 30 seconds with its transcript.")
            }
            let audioID = ObjectIdentifier(refAudio)
            if let cached = referenceCacheLock.withLock({
                cachedReferenceKey?.audioID == audioID && cachedReferenceKey?.transcript == refText
                    ? cachedReferences
                    : nil
            }) {
                references = cached
            } else {
                let samples = refAudio.asType(.float32).asArray(Float.self)
                guard samples.allSatisfy(\.isFinite) else { throw Drama3Error.emptyAudio }
                let built = [DramaReference(audio: SpokenAudio(samples: samples, sampleRate: Double(sampleRate)),
                                            transcript: refText)]
                referenceCacheLock.withLock {
                    cachedReferenceKey = (audioID, refText)
                    cachedReferenceAudio = refAudio
                    cachedReferences = built
                }
                references = built
            }
        }
        // Preserve Say It's sampling settings. Use the library's bounded rewind
        // protection for takes that otherwise continue producing hiss without EOS.
        return (references, DramaSettings(temperature: p.temperature, topK: p.topK, topP: p.topP,
            maxFramesPerChunk: max(1, min(p.maxTokens ?? 1024, 1500)), stopsOnSilence: true,
            seed: p.seed, streamingFrames: Self.clampedStreamingFrames(streamingFrames)))
    }

    // Match the upstream Drama 3 fix: embedded line breaks can end a turn early.
    // Say It retains paragraph boundaries in its separate playback metadata.
    static func promptText(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    func generate(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                  language: String?, generationParameters: GenerateParameters) async throws -> sending MLXArray {
        let input = try inputs(refAudio, refText, generationParameters, streamingFrames: Self.maximumStreamingFrames)
        try Task.checkCancellation()
        let result: (audio: SpokenAudio, report: DramaReport)
        do {
            result = try await engine.synthesize(Self.promptText(text), references: input.references, settings: input.settings)
        } catch DramaError.cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard !result.audio.samples.isEmpty, result.audio.samples.allSatisfy(\.isFinite) else {
            throw Drama3Error.emptyAudio
        }
        if Self.shouldAbortForReport(
            cappedChunks: result.report.cappedChunks,
            silencedChunks: result.report.silencedChunks,
            emittedVoicedAudio: Self.pieceContainsVoicedAudio(result.audio.samples)
        ) {
            throw Drama3Error.generationLimit
        }
        return MLXArray(result.audio.samples)
    }

    /// Pre-encodes the reference clip and warms the 35B backbone/tower prefix
    /// KV-cache inside `DramaEngine` during background preload.
    func warmVoice(refAudio: MLXArray?, refText: String?) async throws {
        let params = GenerateParameters(maxTokens: 1, temperature: 1, topP: 0.9, topK: 30)
        let input = try inputs(refAudio, refText, params, streamingFrames: 1)
        try Task.checkCancellation()
        for try await _ in engine.chunks("Hi.", references: input.references, settings: input.settings) {
            break
        }
    }

    func generateStream(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                        language: String?, generationParameters: GenerateParameters) -> sending AsyncThrowingStream<AudioGeneration, Error> {
        generateStream(text: text, voice: voice, refAudio: refAudio, refText: refText,
                       language: language, generationParameters: generationParameters, streamingInterval: 0.74)
    }

    func generateStream(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                        language: String?, generationParameters: GenerateParameters,
                        streamingInterval: Double) -> sending AsyncThrowingStream<AudioGeneration, Error> {
        let rawStream = generateDirectSamplesStream(
            text: text,
            refAudio: refAudio,
            refText: refText,
            generationParameters: generationParameters,
            streamingFrames: 16
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await samples in rawStream {
                        continuation.yield(.audio(MLXArray(samples)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Streams raw PCM `[Float]` pieces directly from `DramaEngine` without
    /// round-tripping through `MLXArray` and back.
    func generateDirectSamplesStream(
        text: String,
        refAudio: sending MLXArray?,
        refText: String?,
        generationParameters: GenerateParameters,
        streamingFrames: Int = 16
    ) -> sending AsyncThrowingStream<[Float], Error> {
        let input: (references: [DramaReference], settings: DramaSettings)
        do { input = try inputs(refAudio, refText, generationParameters, streamingFrames: streamingFrames) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var emittedVoicedAudio = false
                    for try await piece in engine.chunks(Self.promptText(text), references: input.references, settings: input.settings) {
                        try Task.checkCancellation()
                        guard piece.samples.allSatisfy(\.isFinite) else { throw Drama3Error.emptyAudio }
                        if !piece.samples.isEmpty {
                            if !emittedVoicedAudio, Self.pieceContainsVoicedAudio(piece.samples) {
                                emittedVoicedAudio = true
                            }
                            continuation.yield(piece.samples)
                        }
                        if let report = piece.report,
                           Self.shouldAbortForReport(
                               cappedChunks: report.cappedChunks,
                               silencedChunks: report.silencedChunks,
                               emittedVoicedAudio: emittedVoicedAudio
                           ) {
                            throw Drama3Error.generationLimit
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
