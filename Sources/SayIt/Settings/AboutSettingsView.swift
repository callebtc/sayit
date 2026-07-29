import SwiftUI

struct AboutSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsPage(
            title: "Say It",
            subtitle: "Private text to speech for your Mac."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                LabeledContent("Version", value: state.applicationDisplayVersion)
                LabeledContent("Updates") {
                    HStack {
                        Text(state.updateStatus)
                            .foregroundStyle(.secondary)
                        if state.availableUpdateURL != nil {
                            Button("Download", action: state.openAvailableUpdate)
                        } else {
                            Button("Check", action: state.checkForUpdates)
                        }
                    }
                }
                Text(
                    "Text and generated audio stay local. Network access is used only for model downloads and update checks."
                )
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
                Text("Say It and MLX Audio Swift are distributed under the MIT License.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
