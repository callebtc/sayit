import Foundation

public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case progressive
    case buffered
    case completeFirst
}
