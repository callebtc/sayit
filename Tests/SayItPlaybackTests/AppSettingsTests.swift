import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayIt

@Suite("App settings")
struct AppSettingsTests {
    @Test("Speaking pace persists as a typed setting")
    @MainActor
    func speakingPacePersists() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.speakingPace == .natural)

        settings.speakingPace = .fast

        let restoredSettings = AppSettings(defaults: defaults)
        #expect(restoredSettings.speakingPace == .fast)
    }

    @Test("Voice selections persist independently for each model")
    @MainActor
    func voiceSelectionsPersistPerModel() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let profileID = UUID()
        let settings = AppSettings(defaults: defaults)

        settings.voiceSelections["qwen3-06b-base-8bit"] = .automaticStable
        settings.voiceSelections["omnivoice"] = .profile(profileID)

        let restored = AppSettings(defaults: defaults)
        #expect(
            restored.voiceSelection(for: ModelID("qwen3-06b-base-8bit"))
                == .automaticStable
        )
        #expect(
            restored.voiceSelection(for: ModelID("omnivoice"))
                == .profile(profileID)
        )
    }

    @Test("Model selection uses the dedicated backend command")
    @MainActor
    func modelSelectionDoesNotScheduleSettingsPush() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(defaults: defaults)
        var backendChangeCount = 0
        settings.onBackendChange = {
            backendChangeCount += 1
        }

        settings.activeModelID = ModelID("qwen3-06b-base-8bit")

        #expect(backendChangeCount == 0)
        #expect(
            defaults.string(forKey: "activeModelID")
                == "qwen3-06b-base-8bit"
        )

        settings.speakingPace = .fast
        #expect(backendChangeCount == 1)
    }

    @Test("Advanced settings can be reset to defaults")
    @MainActor
    func advancedSettingsResetToDefaults() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(defaults: defaults)
        let expected = BackendSettingsSnapshot()

        settings.chunkCharacterTarget = 1
        settings.chunkDelaySeconds = 1
        settings.paragraphPauseSeconds = 1
        settings.modelUnloadDelaySeconds = 60
        settings.resetAdvancedSettings()

        #expect(
            settings.chunkCharacterTarget == expected.chunkCharacterTarget
        )
        #expect(settings.chunkDelaySeconds == expected.chunkDelaySeconds)
        #expect(
            settings.paragraphPauseSeconds == expected.paragraphPauseSeconds
        )
        #expect(
            settings.modelUnloadDelaySeconds
                == expected.modelUnloadDelaySeconds
        )
    }
}
