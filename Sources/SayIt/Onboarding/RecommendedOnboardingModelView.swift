import SayItCore
import SwiftUI

struct RecommendedOnboardingModelView: View {
    @Environment(AppState.self) private var state
    let model: ModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "\(model.displayName) · \(voiceLabel)",
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
                .frame(height: 26, alignment: .leading)
        }
        .padding(DesignTokens.generousSpacing)
        .frame(maxWidth: DesignTokens.onboardingCardWidth)
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
                .font(.callout)
                .foregroundStyle(.green)
                Spacer()
                if state.settings.activeModelID == model.id {
                    Button("Play sample", action: state.speakSample)
                        .controlSize(.small)
                } else {
                    Button("Use \(model.displayName)", action: selectModel)
                        .controlSize(.small)
                }
            }
        } else if state.requestedModelInstallID == model.id {
            HStack(spacing: DesignTokens.compactSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting download…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let progress = state.downloadProgress,
                  progress.modelID == model.id {
            OnboardingModelDownloadView(
                progress: progress,
                modelName: model.displayName
            )
        } else if state.downloadProgress == nil,
                  state.requestedModelInstallID == nil {
            HStack {
                Spacer()
                Button("Download \(model.displayName)", action: downloadModel)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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

    private var voiceLabel: String {
        if let defaultVoice = model.defaultVoice {
            defaultVoice
        } else if model.capabilities.voiceDescription {
            "Designed voice"
        } else {
            "Generated voice"
        }
    }
}
