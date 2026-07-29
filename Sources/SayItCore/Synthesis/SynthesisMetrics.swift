import Foundation

public struct SynthesisMetrics: Equatable, Sendable {
    public let chunkIndex: Int
    public let generationDuration: TimeInterval
    public let audioDuration: TimeInterval

    public init(
        chunkIndex: Int,
        generationDuration: TimeInterval,
        audioDuration: TimeInterval
    ) {
        self.chunkIndex = chunkIndex
        self.generationDuration = generationDuration
        self.audioDuration = audioDuration
    }

    public var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return generationDuration / audioDuration
    }
}
