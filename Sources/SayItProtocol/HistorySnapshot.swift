import Foundation

public struct HistorySnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let cleanedText: String
    public let createdAt: Date
    public let modelID: String
    public let voice: String?
    public let voiceSelection: VoiceSelection?
    public let voiceProfileName: String?
    public let language: String?
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
        voiceSelection: VoiceSelection? = nil,
        voiceProfileName: String? = nil,
        language: String? = nil,
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
        self.voiceSelection = voiceSelection
        self.voiceProfileName = voiceProfileName
        self.language = language
        self.duration = duration
        self.state = state
        self.isPinned = isPinned
        self.hasAudio = hasAudio
    }
}
