import Foundation

public struct ModelCapabilities: Codable, Equatable, Sendable {
    public let presetVoices: Bool
    public let voiceDescription: Bool
    public let voiceCloning: Bool
    public let streaming: Bool
    public let longForm: Bool
    public let languageSelection: Bool
    public let requiresReferenceAudio: Bool

    public init(
        presetVoices: Bool,
        voiceDescription: Bool,
        voiceCloning: Bool,
        streaming: Bool,
        longForm: Bool,
        languageSelection: Bool,
        requiresReferenceAudio: Bool
    ) {
        self.presetVoices = presetVoices
        self.voiceDescription = voiceDescription
        self.voiceCloning = voiceCloning
        self.streaming = streaming
        self.longForm = longForm
        self.languageSelection = languageSelection
        self.requiresReferenceAudio = requiresReferenceAudio
    }

    public var canReadAloudInVersionOne: Bool {
        !requiresReferenceAudio
    }
}
