import AppKit
import SwiftUI

struct ErrorStatusView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Label("Couldn’t continue", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .bold()
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Dismiss", action: state.clearError)
                Spacer()
                if let recoveryAction = state.errorRecoveryAction {
                    Button(
                        recoveryAction.buttonTitle,
                        action: state.performErrorRecovery
                    )
                    .buttonStyle(.borderedProminent)
                } else if state.installedModelIDs.isEmpty {
                    Button("Choose a model", action: openOnboarding)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func openOnboarding() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            state.showOnboarding()
            WindowActivator.prepareForWindowPresentation()
            openWindow(id: AppWindowID.onboarding)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
