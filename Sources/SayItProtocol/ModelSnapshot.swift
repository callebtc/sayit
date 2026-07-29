import Foundation

public struct ModelSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let family: String
    public let repository: String
    public let revision: String
    public let modelType: String
    public let parameterCount: String
    public let quantization: String
    public let languages: [String]
    public let voices: [String]
    public let defaultVoice: String?
    public let defaultLanguage: String?
    public let downloadByteCount: Int64
    public let estimatedPeakMemoryBytes: Int64
    public let hardwareTier: String
    public let licenseIdentifier: String
    public let licenseURL: URL
    public let commercialUseAllowed: Bool
    public let requiresLicenseAcceptance: Bool
    public let stability: String
    public let playbackMode: String
    public let hasPresetVoices: Bool
    public let supportsVoiceDescription: Bool
    public let supportsVoiceCloning: Bool
    public let supportsStreaming: Bool
    public let supportsLongForm: Bool
    public let supportsLanguageSelection: Bool
    public let requiresReferenceAudio: Bool
    public let testedMLXAudioVersion: String
    public let testedDate: String
    public let isSelectable: Bool
    public let supportsNativeSpeakingPace: Bool

    public init(
        id: String,
        displayName: String,
        family: String,
        repository: String,
        revision: String,
        modelType: String,
        parameterCount: String,
        quantization: String,
        languages: [String],
        voices: [String],
        defaultVoice: String?,
        defaultLanguage: String?,
        downloadByteCount: Int64,
        estimatedPeakMemoryBytes: Int64,
        hardwareTier: String,
        licenseIdentifier: String,
        licenseURL: URL,
        commercialUseAllowed: Bool,
        requiresLicenseAcceptance: Bool,
        stability: String,
        playbackMode: String,
        hasPresetVoices: Bool,
        supportsVoiceDescription: Bool,
        supportsVoiceCloning: Bool,
        supportsStreaming: Bool,
        supportsLongForm: Bool,
        supportsLanguageSelection: Bool,
        requiresReferenceAudio: Bool,
        testedMLXAudioVersion: String,
        testedDate: String,
        isSelectable: Bool,
        supportsNativeSpeakingPace: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.repository = repository
        self.revision = revision
        self.modelType = modelType
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.languages = languages
        self.voices = voices
        self.defaultVoice = defaultVoice
        self.defaultLanguage = defaultLanguage
        self.downloadByteCount = downloadByteCount
        self.estimatedPeakMemoryBytes = estimatedPeakMemoryBytes
        self.hardwareTier = hardwareTier
        self.licenseIdentifier = licenseIdentifier
        self.licenseURL = licenseURL
        self.commercialUseAllowed = commercialUseAllowed
        self.requiresLicenseAcceptance = requiresLicenseAcceptance
        self.stability = stability
        self.playbackMode = playbackMode
        self.hasPresetVoices = hasPresetVoices
        self.supportsVoiceDescription = supportsVoiceDescription
        self.supportsVoiceCloning = supportsVoiceCloning
        self.supportsStreaming = supportsStreaming
        self.supportsLongForm = supportsLongForm
        self.supportsLanguageSelection = supportsLanguageSelection
        self.requiresReferenceAudio = requiresReferenceAudio
        self.testedMLXAudioVersion = testedMLXAudioVersion
        self.testedDate = testedDate
        self.isSelectable = isSelectable
        self.supportsNativeSpeakingPace = supportsNativeSpeakingPace
    }
}
