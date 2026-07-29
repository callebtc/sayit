import SayItCore
import SwiftUI

struct DownloadStatusView: View {
    @Environment(AppState.self) private var state
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack {
                Label(
                    progress.state == .verifying
                        ? "Verifying model"
                        : "Downloading model",
                    systemImage: progress.state == .verifying
                        ? "checkmark.shield"
                        : "arrow.down.circle"
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
            Button(
                progress.state == .paused ? "Resume" : "Cancel",
                action: progress.state == .paused
                    ? { state.installModel(progress.modelID) }
                    : state.cancelModelInstall
            )
        }
    }
}
