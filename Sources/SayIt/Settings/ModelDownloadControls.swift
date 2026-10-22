import SayItCore
import SwiftUI

struct ModelDownloadControls: View {
    @Environment(AppState.self) private var state

    let model: ModelDescriptor
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            if state.requestedModelInstallID == model.id {
                HStack(spacing: DesignTokens.compactSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                    cancelButton
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Starting \(model.displayName) download")
            } else if let progress = state.downloadProgress,
                      progress.modelID == model.id {
                if state.installedModelIDs.contains(model.id) {
                    Text("Updating voices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: DesignTokens.compactSpacing) {
                    if [.downloading, .paused, .failed].contains(progress.state) {
                        ProgressView(value: progress.fractionCompleted)
                            .frame(width: 76)
                            .accessibilityLabel("\(model.displayName) download")
                            .accessibilityValue(
                                Text(progress.fractionCompleted, format: .percent)
                            )
                        Text(
                            progress.fractionCompleted,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text(statusTitle(for: progress.state))
                            .foregroundStyle(.secondary)
                    }
                    if progress.state == .downloading {
                        Text("\(progress.bytesPerSecond, format: .byteCount(style: .file))/s")
                            .foregroundStyle(.secondary)
                    }
                    if [.failed, .paused].contains(progress.state) {
                        Text(progress.state == .paused ? "Paused" : "Failed")
                            .foregroundStyle(.secondary)
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .labelStyle(.iconOnly)
                            .buttonStyle(CircularIconButtonStyle())
                            .disabled(state.modelInstallIsBusy)
                            .help("Resume the download")
                        Button("Dismiss", systemImage: "xmark", action: state.cancelModelInstall)
                            .labelStyle(.iconOnly)
                            .buttonStyle(CircularIconButtonStyle())
                            .disabled(state.isCancelingModelInstall)
                            .help("Dismiss the download")
                    } else if [.queued, .downloading, .verifying].contains(progress.state) {
                        cancelButton
                    }
                }
            }
        }
        .disabled(!state.isServiceOnline)
    }

    private var cancelButton: some View {
        Button("Cancel", systemImage: "xmark", action: state.cancelModelInstall)
            .labelStyle(.iconOnly)
            .buttonStyle(CircularIconButtonStyle())
            .disabled(state.isCancelingModelInstall)
            .help("Cancel the download")
    }

    private func statusTitle(for state: ModelInstallationState) -> String {
        switch state {
        case .notInstalled: "Waiting"
        case .queued: "Starting…"
        case .canceling: "Canceling…"
        case .verifying, .installed: "Finishing…"
        case .downloading, .paused, .failed: "Downloading…"
        }
    }
}
