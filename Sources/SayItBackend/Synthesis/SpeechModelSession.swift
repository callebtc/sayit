import SayItCore

/// A loaded speech model, exposed without any MLX types. Calls are only
/// made while the synthesis operation gate is held.
protocol SpeechModelSession: Sendable {
    var sampleRate: Double { get }

    /// One-shot generation. `allowTuningSelectedGeneration` is false only
    /// for article-anchor creation, which historically used the model's
    /// standard generation even when the tuning selects an alternative
    /// generation path for voice samples and streamed chunks.
    func generateSamples(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        allowTuningSelectedGeneration: Bool
    ) async throws -> [Float]

    func generateSamplesStream(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) -> AsyncThrowingStream<[Float], Error>

    /// Split one chunk to the model's processed-text budget, using the
    /// actor's configured chunker for the splitting itself.
    func fittingPieces(
        for chunk: SpeechChunk,
        language: String?,
        voice: String?,
        chunker: TextChunker
    ) async throws -> [SpeechChunk]

    /// Apply native speaking pace. Throws
    /// `SynthesisError.speakingPaceUnavailable` when the model descriptor
    /// claims support the loaded model class cannot honour.
    func applySpeakingPace(_ pace: SpeakingPace) throws

    /// Synchronize the runtime and clear its caches, keeping the model
    /// loaded for the next operation.
    func quiesce()

    /// Synchronize the runtime, release the model, and clear its caches.
    func shutdown()
}
