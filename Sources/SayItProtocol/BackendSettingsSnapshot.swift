import Foundation

public struct BackendSettingsSnapshot: Codable, Equatable, Sendable {
    public var activeModelID: String
    public var activeVoice: String
    public var voiceSelections: [String: VoiceSelection]
    public var activeLanguage: String
    public var voiceDescription: String
    public var speakingPace: Double
    public var playbackRate: Double
    public var volume: Double
    public var rewindInterval: Double
    public var forwardInterval: Double
    public var showNowPlayingTitles: Bool
    public var retentionPeriod: String
    public var historyQuotaBytes: Int64
    public var httpEnabled: Bool
    public var httpPort: Int
    public var chunkCharacterTarget: Int
    public var chunkDelaySeconds: Double
    public var paragraphPauseSeconds: Double
    public var modelUnloadDelaySeconds: Double
    public var textCleaningEnabled: Bool
    public var textCleaningStripMarkdown: Bool
    public var textCleaningStripHTML: Bool
    public var textCleaningStripCodeBlocks: Bool
    public var textCleaningStripSpecialCharacters: Bool
    public var textCleaningNormalizeWhitespace: Bool

    public init(
        activeModelID: String = "kokoro-bf16",
        activeVoice: String = "af_heart",
        voiceSelections: [String: VoiceSelection] = [:],
        activeLanguage: String = "en-US",
        voiceDescription: String = "",
        speakingPace: Double = 1,
        playbackRate: Double = 1,
        volume: Double = 1,
        rewindInterval: Double = 15,
        forwardInterval: Double = 30,
        showNowPlayingTitles: Bool = false,
        retentionPeriod: String = "thirtyDays",
        historyQuotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        httpEnabled: Bool = false,
        httpPort: Int = 59_125,
        chunkCharacterTarget: Int = 650,
        chunkDelaySeconds: Double = 0,
        paragraphPauseSeconds: Double = 0.18,
        modelUnloadDelaySeconds: Double = 600,
        textCleaningEnabled: Bool = true,
        textCleaningStripMarkdown: Bool = true,
        textCleaningStripHTML: Bool = true,
        textCleaningStripCodeBlocks: Bool = true,
        textCleaningStripSpecialCharacters: Bool = true,
        textCleaningNormalizeWhitespace: Bool = true
    ) {
        self.activeModelID = activeModelID
        self.activeVoice = activeVoice
        self.voiceSelections = voiceSelections
        self.activeLanguage = activeLanguage
        self.voiceDescription = voiceDescription
        self.speakingPace = speakingPace
        self.playbackRate = playbackRate
        self.volume = volume
        self.rewindInterval = rewindInterval
        self.forwardInterval = forwardInterval
        self.showNowPlayingTitles = showNowPlayingTitles
        self.retentionPeriod = retentionPeriod
        self.historyQuotaBytes = historyQuotaBytes
        self.httpEnabled = httpEnabled
        self.httpPort = httpPort
        self.chunkCharacterTarget = chunkCharacterTarget
        self.chunkDelaySeconds = chunkDelaySeconds
        self.paragraphPauseSeconds = paragraphPauseSeconds
        self.modelUnloadDelaySeconds = modelUnloadDelaySeconds
        self.textCleaningEnabled = textCleaningEnabled
        self.textCleaningStripMarkdown = textCleaningStripMarkdown
        self.textCleaningStripHTML = textCleaningStripHTML
        self.textCleaningStripCodeBlocks = textCleaningStripCodeBlocks
        self.textCleaningStripSpecialCharacters =
            textCleaningStripSpecialCharacters
        self.textCleaningNormalizeWhitespace = textCleaningNormalizeWhitespace
    }

    private enum CodingKeys: String, CodingKey {
        case activeModelID
        case activeVoice
        case voiceSelections
        case activeLanguage
        case voiceDescription
        case speakingPace
        case playbackRate
        case volume
        case rewindInterval
        case forwardInterval
        case showNowPlayingTitles
        case retentionPeriod
        case historyQuotaBytes
        case httpEnabled
        case httpPort
        case chunkCharacterTarget
        case chunkDelaySeconds
        case paragraphPauseSeconds
        case modelUnloadDelaySeconds
        case textCleaningEnabled
        case textCleaningStripMarkdown
        case textCleaningStripHTML
        case textCleaningStripCodeBlocks
        case textCleaningStripSpecialCharacters
        case textCleaningNormalizeWhitespace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeModelID = try container.decodeIfPresent(
            String.self,
            forKey: .activeModelID
        ) ?? "kokoro-bf16"
        activeVoice = try container.decodeIfPresent(
            String.self,
            forKey: .activeVoice
        ) ?? "af_heart"
        voiceSelections = try container.decodeIfPresent(
            [String: VoiceSelection].self,
            forKey: .voiceSelections
        ) ?? [:]
        if voiceSelections[activeModelID] == nil, !activeVoice.isEmpty {
            voiceSelections[activeModelID] = .preset(activeVoice)
        }
        activeLanguage = try container.decodeIfPresent(
            String.self,
            forKey: .activeLanguage
        ) ?? "en-US"
        voiceDescription = try container.decodeIfPresent(
            String.self,
            forKey: .voiceDescription
        ) ?? ""
        speakingPace = try container.decodeIfPresent(
            Double.self,
            forKey: .speakingPace
        ) ?? 1
        playbackRate = try container.decodeIfPresent(
            Double.self,
            forKey: .playbackRate
        ) ?? 1
        volume = try container.decodeIfPresent(
            Double.self,
            forKey: .volume
        ) ?? 1
        rewindInterval = try container.decodeIfPresent(
            Double.self,
            forKey: .rewindInterval
        ) ?? 15
        forwardInterval = try container.decodeIfPresent(
            Double.self,
            forKey: .forwardInterval
        ) ?? 30
        showNowPlayingTitles = try container.decodeIfPresent(
            Bool.self,
            forKey: .showNowPlayingTitles
        ) ?? false
        retentionPeriod = try container.decodeIfPresent(
            String.self,
            forKey: .retentionPeriod
        ) ?? "thirtyDays"
        historyQuotaBytes = try container.decodeIfPresent(
            Int64.self,
            forKey: .historyQuotaBytes
        ) ?? 2 * 1_024 * 1_024 * 1_024
        httpEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .httpEnabled
        ) ?? false
        httpPort = try container.decodeIfPresent(
            Int.self,
            forKey: .httpPort
        ) ?? 59_125
        chunkCharacterTarget = try container.decodeIfPresent(
            Int.self,
            forKey: .chunkCharacterTarget
        ) ?? 650
        chunkDelaySeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .chunkDelaySeconds
        ) ?? 0
        paragraphPauseSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .paragraphPauseSeconds
        ) ?? 0.18
        modelUnloadDelaySeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .modelUnloadDelaySeconds
        ) ?? 600
        textCleaningEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningEnabled
        ) ?? true
        textCleaningStripMarkdown = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningStripMarkdown
        ) ?? true
        textCleaningStripHTML = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningStripHTML
        ) ?? true
        textCleaningStripCodeBlocks = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningStripCodeBlocks
        ) ?? true
        textCleaningStripSpecialCharacters = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningStripSpecialCharacters
        ) ?? true
        textCleaningNormalizeWhitespace = try container.decodeIfPresent(
            Bool.self,
            forKey: .textCleaningNormalizeWhitespace
        ) ?? true
    }
}
