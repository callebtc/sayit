import Foundation

public struct BackendSettingsSnapshot: Codable, Equatable, Sendable {
    public var activeModelID: String
    public var activeVoice: String
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
}
