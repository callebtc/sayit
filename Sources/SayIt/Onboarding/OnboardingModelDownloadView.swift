import SayItCore
import SwiftUI

struct OnboardingModelDownloadView: View {
    @Environment(AppState.self) private var state
    let progress: ModelDownloadProgress
    let modelName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    progress.state == .failed ? Color.red : Color.accentColor
                )
                .accessibilityHidden(true)
            Text(statusTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ProgressView(value: progress.fractionCompleted)
                .frame(width: 90)
                .accessibilityLabel("\(modelName) download")
                .accessibilityValue(
                    Text(progress.fractionCompleted, format: .percent)
                )
            Text(
                progress.fractionCompleted,
                format: .percent.precision(.fractionLength(0))
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            actionButton
        }
        .frame(maxWidth: DesignTokens.onboardingCardWidth)
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actionButton: some View {
        if progress.state == .failed || progress.state == .paused {
            Button("Retry", action: retryDownload)
                .controlSize(.small)
        } else {
            Button(
                "Cancel download",
                systemImage: "xmark.circle.fill",
                action: state.cancelModelInstall
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .imageScale(.medium)
        }
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
            "pause.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .verifying:
            "checkmark.shield.fill"
        default:
            "arrow.down.circle.fill"
        }
    }

    private func retryDownload() {
        state.installModel(
            progress.modelID,
            selectAfterInstallation: true
        )
    }
}
