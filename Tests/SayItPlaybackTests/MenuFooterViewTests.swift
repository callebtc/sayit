import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayIt

@Suite("Menu footer voice label")
@MainActor
struct MenuFooterViewTests {
    @Test("A saved voice replaces the previous preset in the menu label", arguments: [
        VoiceProfileOrigin.generated, .recordedClone, .importedFile
    ])
    func selectedProfileLabel(origin: VoiceProfileOrigin) throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let model = try #require(ModelCatalogLoader().bundledCatalog().models.first {
            $0.id.rawValue == "qwen3-17b-customvoice-8bit"
        })
        let profile = VoiceProfileSnapshot(
            id: UUID(), modelID: model.id.rawValue,
            displayName: "Saved narrator", origin: origin,
            language: "en", duration: 10,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            tuning: .init()
        )
        settings.activeModelID = model.id
        settings.activeVoiceSelection = .preset("ryan")
        settings.activeVoiceSelection = .profile(profile.id)

        #expect(settings.activeVoiceSelection == .profile(profile.id))
        #expect(
            MenuFooterView.modelLabel(
                for: model.id, models: [model],
                settings: settings, profiles: [profile]
            ) == "Qwen3 CustomVoice · Saved narrator"
        )

        settings.activeVoiceSelection = .preset("serena")
        #expect(
            MenuFooterView.modelLabel(
                for: model.id, models: [model],
                settings: settings, profiles: [profile]
            ) == "Qwen3 CustomVoice · serena"
        )
    }

    @Test("Automatic and random selections do not retain a previous preset", arguments: [
        VoiceSelection.automaticStable, .randomPerParagraph
    ])
    func automaticSelectionLabel(selection: VoiceSelection) throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.activeModelID = ModelID("test-model")
        settings.activeVoiceSelection = .preset("ryan")
        settings.activeVoiceSelection = selection

        let label = MenuFooterView.modelLabel(
            for: settings.activeModelID, models: [],
            settings: settings, profiles: []
        )
        #expect(label == (selection == .automaticStable
            ? "test-model · Automatic"
            : "test-model · Random voice every paragraph"))
    }

    @Test("Missing profiles and other playback models never inherit the active preset label")
    func missingProfileLabel() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.activeModelID = ModelID("test-model")
        settings.activeVoiceSelection = .preset("ryan")
        settings.activeVoiceSelection = .profile(UUID())

        #expect(
            MenuFooterView.modelLabel(
                for: settings.activeModelID, models: [],
                settings: settings, profiles: []
            ) == "test-model"
        )
        #expect(
            MenuFooterView.modelLabel(
                for: ModelID("playback-model"), models: [],
                settings: settings, profiles: []
            ) == "playback-model"
        )
    }
}
