import Foundation

public struct SpeechRequest: Identifiable, Sendable {
    public let id: UUID
    public let cleanedText: CleanedText
    public let model: ModelDescriptor
    public let voice: String?
    public let language: String?
    public let voiceDescription: String?
    public let source: TriggerSource
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        cleanedText: CleanedText,
        model: ModelDescriptor,
        voice: String?,
        language: String?,
        voiceDescription: String? = nil,
        source: TriggerSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.cleanedText = cleanedText
        self.model = model
        self.voice = voice
        self.language = language
        self.voiceDescription = voiceDescription
        self.source = source
        self.createdAt = createdAt
    }
}
