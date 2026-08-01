import Foundation

public struct ModelDescriptor: Codable, Identifiable, Equatable, Sendable {
    public let id: ModelID
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
    public let capabilities: ModelCapabilities
    public let playbackMode: PlaybackMode
    public let files: [ModelFileDescriptor]
    public let estimatedDiskBytes: Int64
    public let estimatedPeakMemoryBytes: Int64
    public let hardwareTier: HardwareTier
    public let license: ModelLicense
    public let stability: ModelStability
    public let testedMLXAudioVersion: String
    public let testedDate: String

    public init(
        id: ModelID,
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
        capabilities: ModelCapabilities,
        playbackMode: PlaybackMode,
        files: [ModelFileDescriptor],
        estimatedDiskBytes: Int64,
        estimatedPeakMemoryBytes: Int64,
        hardwareTier: HardwareTier,
        license: ModelLicense,
        stability: ModelStability,
        testedMLXAudioVersion: String,
        testedDate: String
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
        self.capabilities = capabilities
        self.playbackMode = playbackMode
        self.files = files
        self.estimatedDiskBytes = estimatedDiskBytes
        self.estimatedPeakMemoryBytes = estimatedPeakMemoryBytes
        self.hardwareTier = hardwareTier
        self.license = license
        self.stability = stability
        self.testedMLXAudioVersion = testedMLXAudioVersion
        self.testedDate = testedDate
    }

    public var isSelectable: Bool {
        stability != .unavailable && capabilities.canReadAloudInVersionOne
    }

    public var downloadByteCount: Int64 {
        if files.isEmpty {
            estimatedDiskBytes
        } else {
            files.reduce(0) { $0 + $1.byteCount }
        }
    }

    public var supportsNativeSpeakingPace: Bool {
        switch modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            true
        default:
            false
        }
    }

    public func inferredLanguage(forPresetVoice voice: String?) -> String? {
        guard ["kokoro", "kokoro_tts"].contains(modelType.lowercased()),
              let prefix = voice?.first else {
            return nil
        }
        let languageByPrefix: [Character: String] = [
            "a": "en-US",
            "b": "en-GB",
            "e": "es",
            "f": "fr",
            "h": "hi",
            "i": "it",
            "j": "ja",
            "p": "pt",
            "z": "cmn"
        ]
        return languageByPrefix[prefix]
    }
}
