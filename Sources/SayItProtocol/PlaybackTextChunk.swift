import Foundation

public struct PlaybackTextChunk: Codable, Equatable, Sendable {
    public let textStart: Int
    public let textEnd: Int
    public let audioStart: TimeInterval

    public init(
        textStart: Int,
        textEnd: Int,
        audioStart: TimeInterval
    ) {
        self.textStart = textStart
        self.textEnd = textEnd
        self.audioStart = audioStart
    }
}
