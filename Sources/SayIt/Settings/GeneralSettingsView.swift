import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = state.settings

        Form {
            Section {
                Toggle("Launch Say It at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Global shortcut") {
                    ShortcutRecorderView(
                        shortcut: settings.globalShortcut,
                        onRecord: state.updateGlobalShortcut
                    )
                }
                LabeledContent("Selected text") {
                    Text("Services → Say It")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "macOS controls where Services appear. Say It does not need Accessibility permission."
                )
            }

            Section("Playback") {
                Picker("Rewind interval", selection: $settings.rewindInterval) {
                    ForEach([5.0, 10, 15, 30], id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
                .onChange(of: settings.rewindInterval) { _, interval in
                    updateRewindInterval(interval)
                }

                Picker("Forward interval", selection: $settings.forwardInterval) {
                    ForEach([10.0, 15, 30, 60], id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
                .onChange(of: settings.forwardInterval) { _, interval in
                    updateForwardInterval(interval)
                }
            }

            Section("Updates") {
                Toggle(
                    "Check for updates daily",
                    isOn: $settings.checkForUpdates
                )
            }
        }
        .task {
            state.launchAtLogin.refresh()
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }

    private func updateRewindInterval(_ interval: Double) {
        state.playback.backwardSkipInterval = interval
    }

    private func updateForwardInterval(_ interval: Double) {
        state.playback.forwardSkipInterval = interval
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
