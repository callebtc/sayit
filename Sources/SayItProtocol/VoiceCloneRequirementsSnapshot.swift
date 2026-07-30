import Foundation

public struct VoiceCloneRequirementsSnapshot: Codable, Equatable, Sendable {
    public let minimumDuration: TimeInterval
    public let recommendedMinimumDuration: TimeInterval
    public let recommendedMaximumDuration: TimeInterval
    public let maximumDuration: TimeInterval
    public let transcriptRequired: Bool

    public init(
        minimumDuration: TimeInterval,
        recommendedMinimumDuration: TimeInterval,
        recommendedMaximumDuration: TimeInterval,
        maximumDuration: TimeInterval,
        transcriptRequired: Bool
    ) {
        self.minimumDuration = minimumDuration
        self.recommendedMinimumDuration = recommendedMinimumDuration
        self.recommendedMaximumDuration = recommendedMaximumDuration
        self.maximumDuration = maximumDuration
        self.transcriptRequired = transcriptRequired
    }
}
