import Foundation

public protocol SpeechSynthesizing: Sendable {
    func synthesize(
        _ request: SpeechRequest
    ) async -> AsyncThrowingStream<SynthesisEvent, Error>
    func cancelCurrentRequest() async
    func unloadModel() async
}
