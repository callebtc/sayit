import Foundation

public struct BackendSettingsSnapshot: Codable, Equatable, Sendable {
    public var activeModelID: String
    public var activeVoice: String
    public var voiceSelections: [String: VoiceSelection]
    public var activeLanguage: String
    public var voiceDescription: String
    public var speakingPace: Double
    public var playbackRate: Double
    public var rewindInterval: Double
    public var forwardInterval: Double
    public var showNowPlayingTitles: Bool
    public var retentionPeriod: String
    public var historyQuotaBytes: Int64
    public var httpEnabled: Bool
    public var httpPort: Int

    public init(
        activeModelID: String = "kokoro-bf16",
        activeVoice: String = "af_heart",
        voiceSelections: [String: VoiceSelection] = [:],
        activeLanguage: String = "en-US",
        voiceDescription: String = "",
        speakingPace: Double = 1,
        playbackRate: Double = 1,
        rewindInterval: Double = 15,
        forwardInterval: Double = 30,
        showNowPlayingTitles: Bool = false,
        retentionPeriod: String = "thirtyDays",
        historyQuotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        httpEnabled: Bool = false,
        httpPort: Int = 59_125
    ) {
        self.activeModelID = activeModelID
        self.activeVoice = activeVoice
        self.voiceSelections = voiceSelections
        self.activeLanguage = activeLanguage
        self.voiceDescription = voiceDescription
        self.speakingPace = speakingPace
        self.playbackRate = playbackRate
        self.rewindInterval = rewindInterval
        self.forwardInterval = forwardInterval
        self.showNowPlayingTitles = showNowPlayingTitles
        self.retentionPeriod = retentionPeriod
        self.historyQuotaBytes = historyQuotaBytes
        self.httpEnabled = httpEnabled
        self.httpPort = httpPort
    }

    private enum CodingKeys: String, CodingKey {
        case activeModelID
        case activeVoice
        case voiceSelections
        case activeLanguage
        case voiceDescription
        case speakingPace
        case playbackRate
        case rewindInterval
        case forwardInterval
        case showNowPlayingTitles
        case retentionPeriod
        case historyQuotaBytes
        case httpEnabled
        case httpPort
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
    }
}
