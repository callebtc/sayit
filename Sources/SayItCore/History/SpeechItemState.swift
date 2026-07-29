import Foundation

public enum SpeechItemState: String, Codable, CaseIterable, Sendable {
    case generating
    case completed
    case canceled
    case failed
}
