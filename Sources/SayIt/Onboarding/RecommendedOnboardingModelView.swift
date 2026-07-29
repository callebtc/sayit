import SayItCore
import SwiftUI

struct RecommendedOnboardingModelView: View {
    @Environment(AppState.self) private var state
    let model: ModelDescriptor

    var body: some View {
        VStack(spacing: DesignTokens.standardSpacing) {
            LabeledContent {
                Text(
                    state.downloadByteCount(for: model),
                    format: .byteCount(style: .file)
                )
                .monospacedDigit()
            } label: {
                Label(
                    "\(model.displayName) · \(model.defaultVoice ?? "")",
                    systemImage: "speaker.wave.2"
                )
            }

            if state.installedModelIDs.contains(model.id) {
                HStack {
                    Label(
                        "Installed and verified",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    if state.settings.activeModelID == model.id {
                        Button("Play sample", action: state.speakSample)
                    } else {
                        Button(
                            "Use \(model.displayName)",
                            action: selectModel
                        )
                    }
                }
            } else if state.requestedModelInstallID == model.id {
                HStack(spacing: DesignTokens.compactSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting download…")
                }
                .accessibilityElement(children: .combine)
            } else if let progress = state.downloadProgress,
                      progress.modelID == model.id {
                DownloadStatusView(
                    progress: progress,
                    selectAfterDownload: true
                )
            } else if state.downloadProgress == nil,
                      state.requestedModelInstallID == nil {
                Button(
                    "Download \(model.displayName)",
                    action: downloadModel
                )
                .buttonStyle(.borderedProminent)
                .disabled(!state.isServiceOnline)
            }
        }
        .frame(maxWidth: 380)
    }

    private func downloadModel() {
        state.installModel(
            model.id,
            selectAfterInstallation: true
        )
    }

    private func selectModel() {
        state.selectModel(model)
    }
}
