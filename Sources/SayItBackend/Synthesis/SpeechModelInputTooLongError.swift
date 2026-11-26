/// Marker for a generation failure caused by input length. The synthesis
/// actor retries the chunk as subchunks when it sees this error; when the
/// failure is not retried, the actor rethrows `underlyingError` so callers
/// see the original error. Every other generation error is rethrown
/// unchanged by the adapter.
struct SpeechModelInputTooLongError: Error {
    let underlyingError: Error
}
