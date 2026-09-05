import Foundation

public struct PlaybackTextChunk: Codable, Equatable, Sendable {
    public let textStart: Int
    public let textEnd: Int
    public let audioStart: TimeInterval
    public let audioEnd: TimeInterval?

    public init(
        textStart: Int,
        textEnd: Int,
        audioStart: TimeInterval,
        audioEnd: TimeInterval? = nil
    ) {
        self.textStart = textStart
        self.textEnd = textEnd
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }
}
