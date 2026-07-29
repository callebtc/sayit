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
                        Text(state.updateStatus)
                            .foregroundStyle(.secondary)
                    }
                    if state.availableUpdateURL != nil {
                        Button(
                            "Download Update…",
                            action: state.openAvailableUpdate
                        )
                    } else {
                        Button(
                            "Check for Updates…",
                            action: state.checkForUpdates
                        )
                    }
                }

                Section {
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
                        "Text and generated audio stay local. Network access is used only for model downloads and update checks. Say It and MLX Audio Swift are distributed under the MIT License."
                    )
                }
            }
        }
    }
}
