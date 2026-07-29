import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = state.settings

        SettingsPage(
            title: "General",
            subtitle: "Choose how Say It starts and how you invoke it."
        ) {
            Form {
                Toggle("Launch Say It at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }

                LabeledContent("Global shortcut") {
                    ShortcutRecorderView(
                        shortcut: settings.globalShortcut,
                        onRecord: state.updateGlobalShortcut
                    )
                }

                LabeledContent("Selected text service") {
                    Text("Services → Say It")
                        .foregroundStyle(.secondary)
                }

                Text(
                    "macOS controls where Services appear. Say It does not need Accessibility permission."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Picker("Rewind interval", selection: $settings.rewindInterval) {
                    ForEach([5.0, 10, 15, 30], id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
                .onChange(of: settings.rewindInterval) { _, interval in
                    state.playback.backwardSkipInterval = interval
                }

                Picker("Forward interval", selection: $settings.forwardInterval) {
                    ForEach([10.0, 15, 30, 60], id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
                .onChange(of: settings.forwardInterval) { _, interval in
                    state.playback.forwardSkipInterval = interval
                }

                Toggle(
                    "Check for updates daily",
                    isOn: $settings.checkForUpdates
                )
            }
            if let launchError {
                Label(launchError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .task {
            state.launchAtLogin.refresh()
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try state.launchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }
}
