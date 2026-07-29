import Foundation

public enum SpeechJobState: String, Codable, Sendable {
    case queued
    case parsing
    case awaitingConfirmation
    case preparing
    case synthesizing
    case buffering
    case playing
    case paused
    case completed
    case canceled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .canceled, .failed:
            true
        default:
            false
        }
    }
}
