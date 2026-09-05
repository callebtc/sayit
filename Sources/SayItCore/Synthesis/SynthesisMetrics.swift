import Foundation

public struct SynthesisMetrics: Equatable, Sendable {
    public let chunkIndex: Int
    public let generationDuration: TimeInterval
    public let audioDuration: TimeInterval
    public let trailingAudioDuration: TimeInterval

    public init(
        chunkIndex: Int,
        generationDuration: TimeInterval,
        audioDuration: TimeInterval,
        trailingAudioDuration: TimeInterval = 0
    ) {
        self.chunkIndex = chunkIndex
        self.generationDuration = generationDuration
        self.audioDuration = audioDuration
        self.trailingAudioDuration = trailingAudioDuration
    }

    public var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return generationDuration / audioDuration
    }
}
