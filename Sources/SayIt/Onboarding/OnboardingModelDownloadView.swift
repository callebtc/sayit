import SayItCore
import SwiftUI

struct OnboardingModelDownloadView: View {
    @Environment(AppState.self) private var state
    let progress: ModelDownloadProgress
    let modelName: String

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    statusTitle,
                    systemImage: statusSymbol
                )
                ProgressView(value: progress.fractionCompleted)
                    .accessibilityLabel("\(modelName) download")
                    .accessibilityValue(
                        Text(progress.fractionCompleted, format: .percent)
                    )
            }
            Text(
                progress.fractionCompleted,
                format: .percent.precision(.fractionLength(0))
            )
            .monospacedDigit()
            if progress.state == .failed || progress.state == .paused {
                Button("Retry", action: retryDownload)
            } else {
                Button(
                    "Cancel download",
                    systemImage: "xmark.circle",
                    action: state.cancelModelInstall
                )
                .labelStyle(.iconOnly)
            }
        }
        .frame(maxWidth: 380)
    }

    private var statusTitle: String {
        switch progress.state {
        case .paused:
            "\(modelName) download paused"
        case .failed:
            "\(modelName) download failed"
        case .verifying:
            "Verifying \(modelName)"
        default:
            "Downloading \(modelName)"
        }
    }

    private var statusSymbol: String {
        switch progress.state {
        case .paused:
            "pause.circle"
        case .failed:
            "exclamationmark.triangle"
        case .verifying:
            "checkmark.shield"
        default:
            "arrow.down.circle"
        }
    }

    private func retryDownload() {
        state.installModel(
            progress.modelID,
            selectAfterInstallation: true
        )
    }
}
