import Foundation

public enum QueueBlockReason: String, Codable, Sendable {
    case playbackPaused
    case awaitingConfirmation
    case synthesisInProgress
}
