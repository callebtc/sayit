import Foundation

public enum PlaybackState: String, Codable, Sendable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case finished
    case failed
}
