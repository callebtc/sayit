import SwiftUI

struct SettingsRootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings

        TabView(selection: $settings.selectedSettingsPane) {
            Tab(
                SettingsPane.general.title,
                systemImage: SettingsPane.general.symbol,
                value: SettingsPane.general
            ) {
                GeneralSettingsView()
            }
            Tab(
                SettingsPane.speech.title,
                systemImage: SettingsPane.speech.symbol,
                value: SettingsPane.speech
            ) {
                SpeechSettingsView(settings: settings)
            }
            Tab(
                SettingsPane.models.title,
                systemImage: SettingsPane.models.symbol,
                value: SettingsPane.models
            ) {
                ModelsSettingsView()
            }
            Tab(
                SettingsPane.history.title,
                systemImage: SettingsPane.history.symbol,
                value: SettingsPane.history
            ) {
                HistorySettingsView(settings: settings)
            }
            Tab(
                SettingsPane.diagnostics.title,
                systemImage: SettingsPane.diagnostics.symbol,
                value: SettingsPane.diagnostics
            ) {
                DiagnosticsSettingsView()
            }
            Tab(
                SettingsPane.about.title,
                systemImage: SettingsPane.about.symbol,
                value: SettingsPane.about
            ) {
                AboutSettingsView()
            }
        }
        .environment(state)
    }
}
