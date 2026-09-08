import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DesignTokens.compactSpacing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Say It")
                    .font(.title)
                    .bold()
                Text("Version \(state.applicationDisplayVersion)")
                    .foregroundStyle(.secondary)
                Text("Private text to speech for your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Form {
                Section("Updates") {
                    LabeledContent("Status") {
                        HStack(spacing: DesignTokens.compactSpacing) {
                            if state.updates.phase == .checking {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        "Checking for updates"
                                    )
                            }
                            Text(state.updates.status)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(state.updates.hasUpdate ? "Update Now…" : "Check for Updates…") {
                        if state.updates.hasUpdate {
                            state.updates.updateNow()
                        } else {
                            state.checkForUpdates()
                        }
                    }
                    .disabled(state.updates.phase == .unavailable)

                }

                Section {
                    Link("Sparkle", destination: URL(string: "https://sparkle-project.org")!)
                    Link(
                        "MLX Audio Swift",
                        destination: URL(
                            string: "https://github.com/Blaizzy/mlx-audio-swift"
                        ) ?? URL(filePath: "/")
                    )
                    Link(
                        "Model licenses",
                        destination: URL(
                            string: "https://huggingface.co/mlx-community"
                        ) ?? URL(filePath: "/")
                    )
                } header: {
                    Text("Acknowledgements")
                } footer: {
                    Text(
                        "Text and generated audio stay local. Network access is used only for model downloads and software updates. Say It and MLX Audio Swift are distributed under the MIT License."
                    )
                }
            }
        }
    }
}
