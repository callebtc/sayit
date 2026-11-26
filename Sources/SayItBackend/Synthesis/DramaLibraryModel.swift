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

    /// Matches DramaTTS's `SilenceRule` thresholds: a piece is dead air when
    /// quieter than -45 dBFS, or quieter than -30 dBFS with flat (< 2.5 dB)
    /// 50 ms sub-window spread (steady hiss).
    private static let silenceLevelDB: Float = -45
    private static let quietLevelDB: Float = -30
    private static let flatSpreadDB: Float = 2.5
    private static let spreadSubWindowSeconds: Double = 0.05

    let sampleRate = 44_100
    private let engine: DramaEngine
    private let referenceCacheLock = NSLock()
    private var cachedReferenceKey: (audioID: ObjectIdentifier, transcript: String)?
    private var cachedReferenceAudio: MLXArray?
    private var cachedReferences: [DramaReference]?

    static func clampedStreamingFrames(_ requested: Int) -> Int {
        min(max(1, requested), maximumStreamingFrames)
    }

    private static func rmsLevelDB<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return -200 }
        var sumSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let power = sumSquares / Double(samples.count)
        return power > 0 ? Float(10.0 * log10(power)) : -200
    }

    private static func subWindowSpreadDB<C: RandomAccessCollection>(
        _ samples: C,
        window: Int
    ) -> Float where C.Element == Float, C.Index == Int {
        guard window > 0, samples.count >= 2 * window else { return .infinity }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / window)
        var start = samples.startIndex
        while start + window <= samples.endIndex {
            levels.append(max(rmsLevelDB(samples[start..<(start + window)]), -120))
            start += window
        }
        let mean = levels.reduce(Float(0), +) / Float(levels.count)
        let variance = levels.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(levels.count)
        return variance.squareRoot()
    }

    private static func windowContainsVoicedAudio<C: RandomAccessCollection>(
        _ windowSamples: C,
        subWindow: Int
    ) -> Bool where C.Element == Float, C.Index == Int {
        let loudness = rmsLevelDB(windowSamples)
        if loudness < silenceLevelDB {
            return false
        }
        if loudness < quietLevelDB,
           subWindowSpreadDB(windowSamples, window: subWindow) < flatSpreadDB {
            return false
        }
        return true
    }

    static func pieceContainsVoicedAudio(
        _ samples: [Float],
        sampleRate: Double = 44_100
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        let subWindow = max(Int(spreadSubWindowSeconds * sampleRate), 1)
        // Evaluate in <= 0.5 s windows so leading held silence prepended by
        // QuietGate cannot dilute a genuine quiet whisper below -45 dBFS.
        let analysisWindow = max(Int(0.5 * sampleRate), subWindow * 2)
        if samples.count <= analysisWindow {
            return windowContainsVoicedAudio(samples[...], subWindow: subWindow)
        }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + analysisWindow, samples.count)
            if windowContainsVoicedAudio(samples[offset..<end], subWindow: subWindow) {
                return true
            }
            offset = end
        }
        return false
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

    /// Holds back initial unvoiced pieces (such as a QuietGate dead-air tail)
    /// until voiced audio is observed or the stream ends cleanly. If Drama 3
    /// reports a silence/frame limit before any voiced speech appears, the
    /// held-back noise is discarded and `Drama3Error.generationLimit` is thrown
    /// with zero samples emitted so `SynthesisActor` can sub-split and retry.
    struct StreamVoicingGate {
        private(set) var emittedVoicedAudio = false
        private var unvoicedLeadPieces: [[Float]] = []

        mutating func receive(
            samples: [Float],
            cappedChunks: Int,
            silencedChunks: Int
        ) throws -> [[Float]] {
            guard samples.allSatisfy(\.isFinite) else {
                throw Drama3Error.emptyAudio
            }
            var ready: [[Float]] = []
            if !samples.isEmpty {
                if emittedVoicedAudio {
                    ready.append(samples)
                } else if DramaLibraryModel.pieceContainsVoicedAudio(samples) {
                    emittedVoicedAudio = true
                    ready.append(contentsOf: unvoicedLeadPieces)
                    unvoicedLeadPieces.removeAll(keepingCapacity: false)
                    ready.append(samples)
                } else {
                    unvoicedLeadPieces.append(samples)
                }
            }
            if DramaLibraryModel.shouldAbortForReport(
                cappedChunks: cappedChunks,
                silencedChunks: silencedChunks,
                emittedVoicedAudio: emittedVoicedAudio
            ) {
                unvoicedLeadPieces.removeAll(keepingCapacity: false)
                throw Drama3Error.generationLimit
            }
            return ready
        }

        mutating func finish() -> [[Float]] {
            guard !unvoicedLeadPieces.isEmpty else { return [] }
            let remaining = unvoicedLeadPieces
            unvoicedLeadPieces.removeAll(keepingCapacity: false)
            return remaining
        }
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
        guard result.audio.samples.allSatisfy(\.isFinite) else {
            throw Drama3Error.emptyAudio
        }
        if Self.shouldAbortForReport(
            cappedChunks: result.report.cappedChunks,
            silencedChunks: result.report.silencedChunks,
            emittedVoicedAudio: Self.pieceContainsVoicedAudio(result.audio.samples)
        ) {
            throw Drama3Error.generationLimit
        }
        guard !result.audio.samples.isEmpty else {
            throw Drama3Error.emptyAudio
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
        makeManagedDirectSamplesStream(
            text: text,
            refAudio: refAudio,
            refText: refText,
            generationParameters: generationParameters,
            streamingFrames: streamingFrames
        ).stream
    }

    func makeManagedDirectSamplesStream(
        text: String,
        refAudio: sending MLXArray?,
        refText: String?,
        generationParameters: GenerateParameters,
        streamingFrames: Int = 16
    ) -> ManagedSampleStream {
        let input: (references: [DramaReference], settings: DramaSettings)
        do { input = try inputs(refAudio, refText, generationParameters, streamingFrames: streamingFrames) }
        catch {
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
            continuation.finish(throwing: error)
            return ManagedSampleStream(stream: stream, producer: Task {})
        }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let task = Task {
            do {
                var gate = StreamVoicingGate()
                for try await piece in engine.chunks(Self.promptText(text), references: input.references, settings: input.settings) {
                    try Task.checkCancellation()
                    let ready = try gate.receive(
                        samples: piece.samples,
                        cappedChunks: piece.report?.cappedChunks ?? 0,
                        silencedChunks: piece.report?.silencedChunks ?? 0
                    )
                    for samples in ready {
                        continuation.yield(samples)
                    }
                }
                for samples in gate.finish() {
                    continuation.yield(samples)
                }
                continuation.finish()
            } catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : error) }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return ManagedSampleStream(stream: stream, producer: task)
    }
}
