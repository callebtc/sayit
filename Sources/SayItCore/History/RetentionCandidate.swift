import Foundation

public struct RetentionCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let updatedAt: Date
    public let audioByteCount: Int64
    public let isPinned: Bool

    public init(
        id: UUID,
        updatedAt: Date,
        audioByteCount: Int64,
        isPinned: Bool
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.audioByteCount = audioByteCount
        self.isPinned = isPinned
    }
}
