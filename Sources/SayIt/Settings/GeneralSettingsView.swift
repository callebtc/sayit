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

            Section {
                advancedSlider(
                    title: "Text block size",
                    value: chunkTargetBinding,
                    range: 200...2_000,
                    step: 50,
                    label: "\(settings.chunkCharacterTarget) characters"
                )
                advancedSlider(
                    title: "Delay between blocks",
                    value: $settings.chunkDelaySeconds,
                    range: 0...2,
                    step: 0.1,
                    label: settings.chunkDelaySeconds < 0.05
                        ? "Off"
                        : String(format: "%.1f s", settings.chunkDelaySeconds)
                )
                advancedSlider(
                    title: "Pause between paragraphs",
                    value: $settings.paragraphPauseSeconds,
                    range: 0...1,
                    step: 0.05,
                    label: settings.paragraphPauseSeconds < 0.025
                        ? "Off"
                        : String(format: "%.2f s", settings.paragraphPauseSeconds)
                )

                Picker(
                    "Unload model after inactivity",
                    selection: $settings.modelUnloadDelaySeconds
                ) {
                    Text("Never").tag(0.0)
                    Text("After 1 minute").tag(60.0)
                    Text("After 5 minutes").tag(300.0)
                    Text("After 10 minutes").tag(600.0)
                    Text("After 30 minutes").tag(1_800.0)
                    Text("After 1 hour").tag(3_600.0)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text(
                    "Applied to newly spoken text. Keeping the model in memory avoids reload delays."
                )
            }

            Section {
                Toggle(
                    "Clean up text before speaking",
                    isOn: $settings.textCleaningEnabled
                )
                if settings.textCleaningEnabled {
                    Group {
                        Toggle(
                            "Strip Markdown formatting",
                            isOn: $settings.textCleaningStripMarkdown
                        )
                        Toggle(
                            "Strip HTML tags",
                            isOn: $settings.textCleaningStripHTML
                        )
                        Toggle(
                            "Remove code blocks",
                            isOn: $settings.textCleaningStripCodeBlocks
                        )
                        Toggle(
                            "Strip special characters",
                            isOn: $settings.textCleaningStripSpecialCharacters
                        )
                        Toggle(
                            "Normalize whitespace",
                            isOn: $settings.textCleaningNormalizeWhitespace
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                Text("Text cleanup")
            } footer: {
                Text(
                    "Rules applied to clipboard and shared text before it reaches the model."
                )
            }
        }
        .animation(
            DesignTokens.smoothAnimation,
            value: settings.textCleaningEnabled
        )
        .task {
            state.launchAtLogin.refresh()
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }

    private var chunkTargetBinding: Binding<Double> {
        Binding(
            get: { Double(state.settings.chunkCharacterTarget) },
            set: { state.settings.chunkCharacterTarget = Int($0) }
        )
    }

    private func advancedSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value.wrappedValue))
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
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
