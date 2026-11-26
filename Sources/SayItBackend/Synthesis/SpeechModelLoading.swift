import Foundation
import SayItCore

/// Mono reference audio plus its transcript, in adapter-neutral form.
struct SpeechModelReference: Sendable {
    let samples: [Float]
    let transcript: String?

    init(samples: [Float], transcript: String?) {
        self.samples = samples
        self.transcript = transcript
    }
}

/// Marker for a generation failure caused by input length. The synthesis
/// actor retries the chunk as subchunks when it sees this error; every
/// other generation error is rethrown unchanged by the adapter.
struct SpeechModelInputTooLongError: Error {}

/// A loaded speech model, exposed without any MLX types. Calls are only
/// made while the synthesis operation gate is held.
protocol SpeechModelSession: Sendable {
    var sampleRate: Double { get }

    func generateSamples(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) async throws -> [Float]

    func generateSamplesStream(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        streamingInterval: Double
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

/// Port for obtaining a loaded speech model session. Failed or cancelled
/// loads clean up inside the loader, so callers never hold a partial
/// candidate.
protocol SpeechModelLoading: Sendable {
    func load(
        model: ModelDescriptor,
        directory: URL
    ) async throws -> any SpeechModelSession

    /// Prepare model-family dependencies (text processors) without
    /// loading a model.
    func prepareDependencies(for model: ModelDescriptor) async throws
}
