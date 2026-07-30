import Foundation

public struct ModelCapabilities: Codable, Equatable, Sendable {
    public let presetVoices: Bool
    public let voiceDescription: Bool
    public let voiceCloning: Bool
    public let streaming: Bool
    public let longForm: Bool
    public let languageSelection: Bool
    public let requiresReferenceAudio: Bool
    public let voiceDiscovery: Bool?
    public let randomVoiceSampling: Bool?
    public let voiceCloneRequirements: VoiceCloneRequirements?

    public init(
        presetVoices: Bool,
        voiceDescription: Bool,
        voiceCloning: Bool,
        streaming: Bool,
        longForm: Bool,
        languageSelection: Bool,
        requiresReferenceAudio: Bool,
        voiceDiscovery: Bool? = nil,
        randomVoiceSampling: Bool? = nil,
        voiceCloneRequirements: VoiceCloneRequirements? = nil
    ) {
        self.presetVoices = presetVoices
        self.voiceDescription = voiceDescription
        self.voiceCloning = voiceCloning
        self.streaming = streaming
        self.longForm = longForm
        self.languageSelection = languageSelection
        self.requiresReferenceAudio = requiresReferenceAudio
        self.voiceDiscovery = voiceDiscovery
        self.randomVoiceSampling = randomVoiceSampling
        self.voiceCloneRequirements = voiceCloneRequirements
    }

    public var canReadAloudInVersionOne: Bool {
        !requiresReferenceAudio
    }

    public var supportsVoiceDiscovery: Bool {
        voiceDiscovery == true
    }

    public var supportsRandomVoiceSampling: Bool {
        randomVoiceSampling == true
    }
}
