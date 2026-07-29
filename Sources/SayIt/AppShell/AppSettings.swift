import Foundation
import Observation
import SayItCore

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let activeModelID = "activeModelID"
        static let activeVoice = "activeVoice"
        static let activeLanguage = "activeLanguage"
        static let voiceDescription = "voiceDescription"
        static let playbackRate = "playbackRate"
        static let rewindInterval = "rewindInterval"
        static let forwardInterval = "forwardInterval"
        static let showNowPlayingTitles = "showNowPlayingTitles"
        static let retentionPeriod = "retentionPeriod"
        static let historyQuota = "historyQuota"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let selectedSettingsPane = "selectedSettingsPane"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifiers = "shortcutModifiers"
        static let shortcutKeyLabel = "shortcutKeyLabel"
    }

    private let defaults: UserDefaults

    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }
    var activeModelID: ModelID {
        didSet { defaults.set(activeModelID.rawValue, forKey: Key.activeModelID) }
    }
    var activeVoice: String {
        didSet { defaults.set(activeVoice, forKey: Key.activeVoice) }
    }
    var activeLanguage: String {
        didSet { defaults.set(activeLanguage, forKey: Key.activeLanguage) }
    }
    var voiceDescription: String {
        didSet { defaults.set(voiceDescription, forKey: Key.voiceDescription) }
    }
    var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Key.playbackRate) }
    }
    var rewindInterval: Double {
        didSet { defaults.set(rewindInterval, forKey: Key.rewindInterval) }
    }
    var forwardInterval: Double {
        didSet { defaults.set(forwardInterval, forKey: Key.forwardInterval) }
    }
    var showNowPlayingTitles: Bool {
        didSet {
            defaults.set(showNowPlayingTitles, forKey: Key.showNowPlayingTitles)
        }
    }
    var retentionPeriod: RetentionPeriod {
        didSet { defaults.set(retentionPeriod.rawValue, forKey: Key.retentionPeriod) }
    }
    var historyQuotaBytes: Int64 {
        didSet { defaults.set(historyQuotaBytes, forKey: Key.historyQuota) }
    }
    var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }
    var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) }
    }
    var selectedSettingsPane: SettingsPane {
        didSet {
            defaults.set(selectedSettingsPane.rawValue, forKey: Key.selectedSettingsPane)
        }
    }
    var shortcutKeyCode: UInt32 {
        didSet { defaults.set(Int(shortcutKeyCode), forKey: Key.shortcutKeyCode) }
    }
    var shortcutModifiers: UInt32 {
        didSet { defaults.set(Int(shortcutModifiers), forKey: Key.shortcutModifiers) }
    }
    var shortcutKeyLabel: String {
        didSet { defaults.set(shortcutKeyLabel, forKey: Key.shortcutKeyLabel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        activeModelID = ModelID(
            defaults.string(forKey: Key.activeModelID) ?? "kokoro-bf16"
        )
        activeVoice = defaults.string(forKey: Key.activeVoice) ?? "af_heart"
        activeLanguage = defaults.string(forKey: Key.activeLanguage) ?? "en-US"
        voiceDescription = defaults.string(forKey: Key.voiceDescription) ?? ""
        let storedRate = defaults.double(forKey: Key.playbackRate)
        playbackRate = storedRate == 0 ? 1 : storedRate
        let storedRewind = defaults.double(forKey: Key.rewindInterval)
        rewindInterval = storedRewind == 0 ? 15 : storedRewind
        let storedForward = defaults.double(forKey: Key.forwardInterval)
        forwardInterval = storedForward == 0 ? 30 : storedForward
        showNowPlayingTitles = defaults.bool(forKey: Key.showNowPlayingTitles)
        retentionPeriod = RetentionPeriod(
            rawValue: defaults.string(forKey: Key.retentionPeriod) ?? ""
        ) ?? .thirtyDays
        let storedQuota = defaults.object(forKey: Key.historyQuota) as? Int64
        historyQuotaBytes = storedQuota ?? 2 * 1_024 * 1_024 * 1_024
        checkForUpdates = defaults.object(forKey: Key.checkForUpdates) == nil
            ? true
            : defaults.bool(forKey: Key.checkForUpdates)
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
        selectedSettingsPane = SettingsPane(
            rawValue: defaults.string(forKey: Key.selectedSettingsPane) ?? ""
        ) ?? .general
        let defaultShortcut = GlobalShortcut.defaultShortcut
        shortcutKeyCode = UInt32(
            defaults.object(forKey: Key.shortcutKeyCode) as? Int
                ?? Int(defaultShortcut.keyCode)
        )
        shortcutModifiers = UInt32(
            defaults.object(forKey: Key.shortcutModifiers) as? Int
                ?? Int(defaultShortcut.carbonModifiers)
        )
        shortcutKeyLabel = defaults.string(forKey: Key.shortcutKeyLabel)
            ?? defaultShortcut.keyLabel
    }

    var globalShortcut: GlobalShortcut {
        GlobalShortcut(
            keyCode: shortcutKeyCode,
            carbonModifiers: shortcutModifiers,
            keyLabel: shortcutKeyLabel
        )
    }
}
