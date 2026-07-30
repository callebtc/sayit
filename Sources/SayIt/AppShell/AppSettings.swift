import Foundation
import Observation
import SayItCore
import SayItProtocol

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let activeModelID = "activeModelID"
        static let activeVoice = "activeVoice"
        static let voiceSelections = "voiceSelections"
        static let activeLanguage = "activeLanguage"
        static let voiceDescription = "voiceDescription"
        static let voicePreviewSample = "voicePreviewSample"
        static let speakingPace = "speakingPace"
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
        static let chunkCharacterTarget = "chunkCharacterTarget"
        static let chunkDelaySeconds = "chunkDelaySeconds"
        static let paragraphPauseSeconds = "paragraphPauseSeconds"
        static let modelUnloadDelaySeconds = "modelUnloadDelaySeconds"
        static let showLyricsBlockSeparators = "showLyricsBlockSeparators"
        static let textCleaningEnabled = "textCleaningEnabled"
        static let textCleaningStripMarkdown = "textCleaningStripMarkdown"
        static let textCleaningStripHTML = "textCleaningStripHTML"
        static let textCleaningStripCodeBlocks = "textCleaningStripCodeBlocks"
        static let textCleaningStripSpecialCharacters =
            "textCleaningStripSpecialCharacters"
        static let textCleaningNormalizeWhitespace =
            "textCleaningNormalizeWhitespace"
    }

    private let defaults: UserDefaults
    @ObservationIgnored
    private var isApplyingBackendSnapshot = false
    @ObservationIgnored
    var onBackendChange: (() -> Void)?

    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }
    var activeModelID: ModelID {
        didSet {
            defaults.set(activeModelID.rawValue, forKey: Key.activeModelID)
            let wasApplyingBackendSnapshot = isApplyingBackendSnapshot
            isApplyingBackendSnapshot = true
            synchronizeLegacyVoice()
            isApplyingBackendSnapshot = wasApplyingBackendSnapshot
        }
    }
    var activeVoice: String {
        didSet {
            defaults.set(activeVoice, forKey: Key.activeVoice)
            notifyBackendChange()
        }
    }
    var voiceSelections: [String: VoiceSelection] {
        didSet {
            if let data = try? JSONEncoder.sayIt.encode(voiceSelections) {
                defaults.set(data, forKey: Key.voiceSelections)
            }
            synchronizeLegacyVoice()
            notifyBackendChange()
        }
    }
    var activeLanguage: String {
        didSet {
            defaults.set(activeLanguage, forKey: Key.activeLanguage)
            notifyBackendChange()
        }
    }
    var voiceDescription: String {
        didSet {
            defaults.set(voiceDescription, forKey: Key.voiceDescription)
            notifyBackendChange()
        }
    }
    var voicePreviewSample: String {
        didSet {
            defaults.set(voicePreviewSample, forKey: Key.voicePreviewSample)
        }
    }
    var speakingPace: SpeakingPace {
        didSet {
            defaults.set(speakingPace.rawValue, forKey: Key.speakingPace)
            notifyBackendChange()
        }
    }
    var playbackRate: Double {
        didSet {
            defaults.set(playbackRate, forKey: Key.playbackRate)
            notifyBackendChange()
        }
    }
    var rewindInterval: Double {
        didSet {
            defaults.set(rewindInterval, forKey: Key.rewindInterval)
            notifyBackendChange()
        }
    }
    var forwardInterval: Double {
        didSet {
            defaults.set(forwardInterval, forKey: Key.forwardInterval)
            notifyBackendChange()
        }
    }
    var showNowPlayingTitles: Bool {
        didSet {
            defaults.set(showNowPlayingTitles, forKey: Key.showNowPlayingTitles)
            notifyBackendChange()
        }
    }
    var retentionPeriod: RetentionPeriod {
        didSet {
            defaults.set(retentionPeriod.rawValue, forKey: Key.retentionPeriod)
            notifyBackendChange()
        }
    }
    var historyQuotaBytes: Int64 {
        didSet {
            defaults.set(historyQuotaBytes, forKey: Key.historyQuota)
            notifyBackendChange()
        }
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
    var chunkCharacterTarget: Int {
        didSet {
            defaults.set(chunkCharacterTarget, forKey: Key.chunkCharacterTarget)
            notifyBackendChange()
        }
    }
    var chunkDelaySeconds: Double {
        didSet {
            defaults.set(chunkDelaySeconds, forKey: Key.chunkDelaySeconds)
            notifyBackendChange()
        }
    }
    var paragraphPauseSeconds: Double {
        didSet {
            defaults.set(paragraphPauseSeconds, forKey: Key.paragraphPauseSeconds)
            notifyBackendChange()
        }
    }
    var modelUnloadDelaySeconds: Double {
        didSet {
            defaults.set(
                modelUnloadDelaySeconds,
                forKey: Key.modelUnloadDelaySeconds
            )
            notifyBackendChange()
        }
    }
    var showLyricsBlockSeparators: Bool {
        didSet {
            defaults.set(
                showLyricsBlockSeparators,
                forKey: Key.showLyricsBlockSeparators
            )
        }
    }
    var textCleaningEnabled: Bool {
        didSet {
            defaults.set(textCleaningEnabled, forKey: Key.textCleaningEnabled)
            notifyBackendChange()
        }
    }
    var textCleaningStripMarkdown: Bool {
        didSet {
            defaults.set(
                textCleaningStripMarkdown,
                forKey: Key.textCleaningStripMarkdown
            )
            notifyBackendChange()
        }
    }
    var textCleaningStripHTML: Bool {
        didSet {
            defaults.set(textCleaningStripHTML, forKey: Key.textCleaningStripHTML)
            notifyBackendChange()
        }
    }
    var textCleaningStripCodeBlocks: Bool {
        didSet {
            defaults.set(
                textCleaningStripCodeBlocks,
                forKey: Key.textCleaningStripCodeBlocks
            )
            notifyBackendChange()
        }
    }
    var textCleaningStripSpecialCharacters: Bool {
        didSet {
            defaults.set(
                textCleaningStripSpecialCharacters,
                forKey: Key.textCleaningStripSpecialCharacters
            )
            notifyBackendChange()
        }
    }
    var textCleaningNormalizeWhitespace: Bool {
        didSet {
            defaults.set(
                textCleaningNormalizeWhitespace,
                forKey: Key.textCleaningNormalizeWhitespace
            )
            notifyBackendChange()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        let storedModelID = ModelID(
            defaults.string(forKey: Key.activeModelID) ?? "kokoro-bf16"
        )
        let storedVoice = defaults.string(forKey: Key.activeVoice)
            ?? "af_heart"
        activeModelID = storedModelID
        activeVoice = storedVoice
        if let data = defaults.data(forKey: Key.voiceSelections),
           let selections = try? JSONDecoder.sayIt.decode(
               [String: VoiceSelection].self,
               from: data
           ) {
            voiceSelections = selections
        } else {
            voiceSelections = [
                storedModelID.rawValue: .preset(storedVoice)
            ]
        }
        activeLanguage = defaults.string(forKey: Key.activeLanguage) ?? "en-US"
        voiceDescription = defaults.string(forKey: Key.voiceDescription) ?? ""
        voicePreviewSample = defaults.string(forKey: Key.voicePreviewSample)
            ?? "Say It turns the words on your Mac into calm, private audio."
        speakingPace = SpeakingPace(
            rawValue: defaults.double(forKey: Key.speakingPace)
        ) ?? .natural
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
        let storedChunkTarget = defaults.object(
            forKey: Key.chunkCharacterTarget
        ) as? Int
        chunkCharacterTarget = storedChunkTarget ?? 650
        chunkDelaySeconds = defaults.double(forKey: Key.chunkDelaySeconds)
        let storedParagraphPause = defaults.object(
            forKey: Key.paragraphPauseSeconds
        ) as? Double
        paragraphPauseSeconds = storedParagraphPause ?? 0.18
        let storedUnloadDelay = defaults.object(
            forKey: Key.modelUnloadDelaySeconds
        ) as? Double
        modelUnloadDelaySeconds = storedUnloadDelay ?? 600
        showLyricsBlockSeparators = defaults.bool(
            forKey: Key.showLyricsBlockSeparators
        )
        textCleaningEnabled = defaults.object(
            forKey: Key.textCleaningEnabled
        ) as? Bool ?? true
        textCleaningStripMarkdown = defaults.object(
            forKey: Key.textCleaningStripMarkdown
        ) as? Bool ?? true
        textCleaningStripHTML = defaults.object(
            forKey: Key.textCleaningStripHTML
        ) as? Bool ?? true
        textCleaningStripCodeBlocks = defaults.object(
            forKey: Key.textCleaningStripCodeBlocks
        ) as? Bool ?? true
        textCleaningStripSpecialCharacters = defaults.object(
            forKey: Key.textCleaningStripSpecialCharacters
        ) as? Bool ?? true
        textCleaningNormalizeWhitespace = defaults.object(
            forKey: Key.textCleaningNormalizeWhitespace
        ) as? Bool ?? true
    }

    var globalShortcut: GlobalShortcut {
        GlobalShortcut(
            keyCode: shortcutKeyCode,
            carbonModifiers: shortcutModifiers,
            keyLabel: shortcutKeyLabel
        )
    }

    func backendSnapshot(
        httpEnabled: Bool = false,
        httpPort: Int = 59_125
    ) -> BackendSettingsSnapshot {
        BackendSettingsSnapshot(
            activeModelID: activeModelID.rawValue,
            activeVoice: activeVoice,
            voiceSelections: voiceSelections,
            activeLanguage: activeLanguage,
            voiceDescription: voiceDescription,
            speakingPace: speakingPace.rawValue,
            playbackRate: playbackRate,
            rewindInterval: rewindInterval,
            forwardInterval: forwardInterval,
            showNowPlayingTitles: showNowPlayingTitles,
            retentionPeriod: retentionPeriod.rawValue,
            historyQuotaBytes: historyQuotaBytes,
            httpEnabled: httpEnabled,
            httpPort: httpPort,
            chunkCharacterTarget: chunkCharacterTarget,
            chunkDelaySeconds: chunkDelaySeconds,
            paragraphPauseSeconds: paragraphPauseSeconds,
            modelUnloadDelaySeconds: modelUnloadDelaySeconds,
            textCleaningEnabled: textCleaningEnabled,
            textCleaningStripMarkdown: textCleaningStripMarkdown,
            textCleaningStripHTML: textCleaningStripHTML,
            textCleaningStripCodeBlocks: textCleaningStripCodeBlocks,
            textCleaningStripSpecialCharacters:
                textCleaningStripSpecialCharacters,
            textCleaningNormalizeWhitespace: textCleaningNormalizeWhitespace
        )
    }

    func apply(_ snapshot: BackendSettingsSnapshot) {
        isApplyingBackendSnapshot = true
        activeModelID = ModelID(snapshot.activeModelID)
        activeVoice = snapshot.activeVoice
        voiceSelections = snapshot.voiceSelections
        activeLanguage = snapshot.activeLanguage
        voiceDescription = snapshot.voiceDescription
        speakingPace = SpeakingPace(rawValue: snapshot.speakingPace)
            ?? .natural
        playbackRate = snapshot.playbackRate
        rewindInterval = snapshot.rewindInterval
        forwardInterval = snapshot.forwardInterval
        showNowPlayingTitles = snapshot.showNowPlayingTitles
        retentionPeriod = RetentionPeriod(
            rawValue: snapshot.retentionPeriod
        ) ?? .thirtyDays
        historyQuotaBytes = snapshot.historyQuotaBytes
        chunkCharacterTarget = snapshot.chunkCharacterTarget
        chunkDelaySeconds = snapshot.chunkDelaySeconds
        paragraphPauseSeconds = snapshot.paragraphPauseSeconds
        modelUnloadDelaySeconds = snapshot.modelUnloadDelaySeconds
        textCleaningEnabled = snapshot.textCleaningEnabled
        textCleaningStripMarkdown = snapshot.textCleaningStripMarkdown
        textCleaningStripHTML = snapshot.textCleaningStripHTML
        textCleaningStripCodeBlocks = snapshot.textCleaningStripCodeBlocks
        textCleaningStripSpecialCharacters =
            snapshot.textCleaningStripSpecialCharacters
        textCleaningNormalizeWhitespace =
            snapshot.textCleaningNormalizeWhitespace
        isApplyingBackendSnapshot = false
    }

    func resetAdvancedSettings() {
        let defaultSettings = BackendSettingsSnapshot()
        chunkCharacterTarget = defaultSettings.chunkCharacterTarget
        chunkDelaySeconds = defaultSettings.chunkDelaySeconds
        paragraphPauseSeconds = defaultSettings.paragraphPauseSeconds
        modelUnloadDelaySeconds = defaultSettings.modelUnloadDelaySeconds
        showLyricsBlockSeparators = false
    }

    var activeVoiceSelection: VoiceSelection {
        get {
            voiceSelections[activeModelID.rawValue]
                ?? fallbackVoiceSelection
        }
        set {
            voiceSelections[activeModelID.rawValue] = newValue
        }
    }

    func voiceSelection(for modelID: ModelID) -> VoiceSelection? {
        voiceSelections[modelID.rawValue]
    }

    private func notifyBackendChange() {
        guard !isApplyingBackendSnapshot else { return }
        onBackendChange?()
    }

    private var fallbackVoiceSelection: VoiceSelection {
        activeVoice.isEmpty ? .automaticStable : .preset(activeVoice)
    }

    private func synchronizeLegacyVoice() {
        guard case .preset(let voice) =
            voiceSelections[activeModelID.rawValue] else {
            return
        }
        if activeVoice != voice {
            activeVoice = voice
        }
    }
}
