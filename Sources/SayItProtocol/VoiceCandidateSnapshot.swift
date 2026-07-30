import Foundation

public struct VoiceCandidateSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let suggestedName: String
    public let duration: TimeInterval
    public let fingerprint: [Float]

    public init(
        id: UUID,
        suggestedName: String,
        duration: TimeInterval,
        fingerprint: [Float]
    ) {
        self.id = id
        self.suggestedName = suggestedName
        self.duration = duration
        self.fingerprint = fingerprint
    }
}
