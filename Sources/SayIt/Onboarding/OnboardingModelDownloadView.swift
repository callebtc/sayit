import SayItCore
import SwiftUI

struct OnboardingModelDownloadView: View {
    @Environment(AppState.self) private var state
    let progress: ModelDownloadProgress
    let modelName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: DesignTokens.onboardingCardWidth)
        .accessibilityElement(children: .contain)
        .help(failureMessage ?? "")
    }

    private var statusRow: some View {
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
            if showsDeterminateProgress {
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
            } else if progress.state != .failed {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 90)
                    .accessibilityLabel(statusTitle)
                Text("Working")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            actionButton
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder private var actionButton: some View {
        if progress.state == .failed || progress.state == .paused {
            HStack(spacing: 4) {
                Button("Retry", action: retryDownload)
                    .controlSize(.small)
                Button(
                    "Dismiss download",
                    systemImage: "xmark.circle.fill",
                    action: state.cancelModelInstall
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        } else if progress.state != .canceling
                    && progress.state != .installed
                    && progress.state != .notInstalled {
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
        case .notInstalled:
            "Ready to download \(modelName)"
        case .queued:
            "Preparing \(modelName) download"
        case .canceling:
            "Canceling \(modelName) download"
        case .paused:
            "\(modelName) download paused"
        case .failed:
            "Download failed"
        case .verifying:
            "Finishing \(modelName) setup"
        case .installed:
            "Finishing \(modelName) setup"
        case .downloading:
            "Downloading \(modelName)"
        }
    }

    private var statusSymbol: String {
        switch progress.state {
        case .notInstalled:
            "arrow.down.circle"
        case .queued:
            "clock.arrow.circlepath"
        case .canceling:
            "xmark.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .verifying:
            "checkmark.shield.fill"
        case .installed:
            "checkmark.circle.fill"
        case .downloading:
            "arrow.down.circle.fill"
        }
    }

    private var showsDeterminateProgress: Bool {
        switch progress.state {
        case .downloading, .paused:
            true
        case .notInstalled, .queued, .canceling, .verifying, .installed, .failed:
            false
        }
    }

    private var failureMessage: String? {
        guard progress.state == .failed,
              state.modelInstallError?.modelID == progress.modelID else {
            return nil
        }
        return state.modelInstallError?.message
    }

    private func retryDownload() {
        state.installModel(
            progress.modelID,
            selectAfterInstallation: true
        )
    }
}
