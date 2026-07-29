import SwiftUI

struct SettingsRootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings

        Group {
            switch settings.selectedSettingsPane {
            case .general:
                GeneralSettingsView()
            case .speech:
                SpeechSettingsView(settings: settings)
            case .models:
                ModelsSettingsView()
            case .history:
                HistorySettingsView(settings: settings)
            case .diagnostics:
                DiagnosticsSettingsView()
            case .about:
                AboutSettingsView()
            }
        }
        .environment(state)
        .navigationTitle(settings.selectedSettingsPane.title)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        settings.selectedSettingsPane = pane
                    } label: {
                        Label(pane.title, systemImage: pane.symbol)
                    }
                    .help(pane.title)
                    .accessibilityAddTraits(
                        settings.selectedSettingsPane == pane
                            ? .isSelected
                            : []
                    )
                }
            }
        }
    }
}
