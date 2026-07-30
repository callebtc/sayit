import Foundation

public struct SpeechRequest: Identifiable, Sendable {
    public let id: UUID
    public let cleanedText: CleanedText
    public let model: ModelDescriptor
    public let voice: String?
    public let language: String?
    public let voiceDescription: String?
    public let voiceMode: VoiceSynthesisMode
    public let voiceReference: VoiceReference?
    public let voiceProfileID: UUID?
    public let voiceProfileName: String?
    public let voiceTuning: VoiceSynthesisTuning?
    public let speakingPace: SpeakingPace
    public let source: TriggerSource
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        cleanedText: CleanedText,
        model: ModelDescriptor,
        voice: String?,
        language: String?,
        voiceDescription: String? = nil,
        voiceMode: VoiceSynthesisMode = .standard,
        voiceReference: VoiceReference? = nil,
        voiceProfileID: UUID? = nil,
        voiceProfileName: String? = nil,
        voiceTuning: VoiceSynthesisTuning? = nil,
        speakingPace: SpeakingPace = .natural,
        source: TriggerSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.cleanedText = cleanedText
        self.model = model
        self.voice = voice
        self.language = language
        self.voiceDescription = voiceDescription
        self.voiceMode = voiceMode
        self.voiceReference = voiceReference
        self.voiceProfileID = voiceProfileID
        self.voiceProfileName = voiceProfileName
        self.voiceTuning = voiceTuning
        self.speakingPace = speakingPace
        self.source = source
        self.createdAt = createdAt
    }
}
