import SayItCore
import SwiftUI

struct RecommendedOnboardingModelView: View {
    @Environment(AppState.self) private var state
    let model: ModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "\(model.displayName) · \(model.defaultVoice ?? "")",
                    systemImage: "speaker.wave.2.fill"
                )
                .font(.headline)
                Spacer()
                Text(
                    state.downloadByteCount(for: model),
                    format: .byteCount(style: .file)
                )
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            statusRow
        }
        .padding(DesignTokens.generousSpacing)
        .frame(maxWidth: 400)
        .background(
            .quaternary.opacity(0.55),
            in: .rect(cornerRadius: DesignTokens.cardCornerRadius)
        )
    }

    @ViewBuilder private var statusRow: some View {
        if state.installedModelIDs.contains(model.id) {
            HStack {
                Label(
                    "Installed and verified",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                Spacer()
                if state.settings.activeModelID == model.id {
                    Button("Play sample", action: state.speakSample)
                } else {
                    Button("Use \(model.displayName)", action: selectModel)
                }
            }
        } else if state.requestedModelInstallID == model.id {
            HStack(spacing: DesignTokens.compactSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting download…")
                    .foregroundStyle(.secondary)
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
            HStack {
                Spacer()
                Button("Download \(model.displayName)", action: downloadModel)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.isServiceOnline)
            }
        }
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
