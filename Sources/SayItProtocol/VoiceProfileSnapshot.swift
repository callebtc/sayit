import Foundation

public struct VoiceProfileSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let modelID: String
    public let displayName: String
    public let origin: VoiceProfileOrigin
    public let language: String?
    public let duration: TimeInterval
    public let createdAt: Date
    public let updatedAt: Date
    public let tuning: VoiceTuning

    public init(
        id: UUID,
        modelID: String,
        displayName: String,
        origin: VoiceProfileOrigin,
        language: String?,
        duration: TimeInterval,
        createdAt: Date,
        updatedAt: Date,
        tuning: VoiceTuning
    ) {
        self.id = id
        self.modelID = modelID
        self.displayName = displayName
        self.origin = origin
        self.language = language
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tuning = tuning
    }
}
