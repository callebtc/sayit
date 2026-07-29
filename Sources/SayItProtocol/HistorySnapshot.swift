import Foundation

public struct HistorySnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let cleanedText: String
    public let createdAt: Date
    public let modelID: String
    public let voice: String?
    public let duration: TimeInterval
    public let state: String
    public let isPinned: Bool
    public let hasAudio: Bool

    public init(
        id: UUID,
        title: String,
        cleanedText: String,
        createdAt: Date,
        modelID: String,
        voice: String?,
        duration: TimeInterval,
        state: String,
        isPinned: Bool,
        hasAudio: Bool
    ) {
        self.id = id
        self.title = title
        self.cleanedText = cleanedText
        self.createdAt = createdAt
        self.modelID = modelID
        self.voice = voice
        self.duration = duration
        self.state = state
        self.isPinned = isPinned
        self.hasAudio = hasAudio
    }
}
