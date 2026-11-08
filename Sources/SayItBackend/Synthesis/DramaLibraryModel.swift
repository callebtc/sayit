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
    let sampleRate = 44_100
    private let engine: DramaEngine

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

    private func inputs(_ refAudio: MLXArray?, _ refText: String?, _ p: GenerateParameters)
        throws -> (references: [DramaReference], settings: DramaSettings) {
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
            let samples = refAudio.asType(.float32).asArray(Float.self)
            guard samples.allSatisfy(\.isFinite) else { throw Drama3Error.emptyAudio }
            references = [DramaReference(audio: SpokenAudio(samples: samples, sampleRate: Double(sampleRate)),
                                         transcript: refText)]
        }
        // Preserve Say It's sampling settings. Use the library's bounded rewind
        // protection for takes that otherwise continue producing hiss without EOS.
        return (references, DramaSettings(temperature: p.temperature, topK: p.topK, topP: p.topP,
            maxFramesPerChunk: max(1, min(p.maxTokens ?? 1024, 1500)), stopsOnSilence: true,
            seed: p.seed, streamingFrames: 16))
    }

    // Match the upstream Drama 3 fix: embedded line breaks can end a turn early.
    // Say It retains paragraph boundaries in its separate playback metadata.
    static func promptText(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    func generate(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                  language: String?, generationParameters: GenerateParameters) async throws -> sending MLXArray {
        let input = try inputs(refAudio, refText, generationParameters)
        try Task.checkCancellation()
        let result: (audio: SpokenAudio, report: DramaReport)
        do {
            result = try await engine.synthesize(Self.promptText(text), references: input.references, settings: input.settings)
        } catch DramaError.cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard result.report.cappedChunks == 0, result.report.silencedChunks == 0 else {
            throw Drama3Error.generationLimit
        }
        guard !result.audio.samples.isEmpty, result.audio.samples.allSatisfy(\.isFinite) else {
            throw Drama3Error.emptyAudio
        }
        return MLXArray(result.audio.samples)
    }

    func generateStream(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                        language: String?, generationParameters: GenerateParameters) -> sending AsyncThrowingStream<AudioGeneration, Error> {
        generateStream(text: text, voice: voice, refAudio: refAudio, refText: refText,
                       language: language, generationParameters: generationParameters, streamingInterval: 0.74)
    }

    func generateStream(text: String, voice: String?, refAudio: sending MLXArray?, refText: String?,
                        language: String?, generationParameters: GenerateParameters,
                        streamingInterval: Double) -> sending AsyncThrowingStream<AudioGeneration, Error> {
        let input: (references: [DramaReference], settings: DramaSettings)
        do { input = try inputs(refAudio, refText, generationParameters) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in engine.chunks(Self.promptText(text), references: input.references, settings: input.settings) {
                        try Task.checkCancellation()
                        if let report = piece.report, report.cappedChunks > 0 || report.silencedChunks > 0 {
                            throw Drama3Error.generationLimit
                        }
                        guard piece.samples.allSatisfy(\.isFinite) else { throw Drama3Error.emptyAudio }
                        if !piece.samples.isEmpty { continuation.yield(.audio(MLXArray(piece.samples))) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
