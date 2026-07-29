import SayItCore
import SwiftUI

struct DownloadStatusView: View {
    @Environment(AppState.self) private var state
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack {
                Label(
                    statusTitle,
                    systemImage: statusSymbol
                )
                .bold()
                Spacer()
                Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            ProgressView(value: progress.fractionCompleted)
                .accessibilityLabel("Model download")
                .accessibilityValue(
                    Text(progress.fractionCompleted, format: .percent)
                )
            HStack {
                Text(progress.completedBytes, format: .byteCount(style: .file))
                Text("of")
                Text(progress.totalBytes, format: .byteCount(style: .file))
                Spacer()
                if progress.bytesPerSecond > 0 {
                    Text(progress.bytesPerSecond, format: .byteCount(style: .file))
                    Text("/s")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if progress.state == .failed, let message = state.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(actionTitle, action: performAction)
        }
    }

    private var statusTitle: String {
        switch progress.state {
        case .paused:
            "Download paused"
        case .failed:
            "Download failed"
        case .verifying:
            "Verifying model"
        default:
            "Downloading model"
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

    private var actionTitle: String {
        switch progress.state {
        case .paused:
            "Resume"
        case .failed:
            "Retry"
        default:
            "Cancel"
        }
    }

    private func performAction() {
        switch progress.state {
        case .paused, .failed:
            state.installModel(progress.modelID)
        default:
            state.cancelModelInstall()
        }
    }
}
