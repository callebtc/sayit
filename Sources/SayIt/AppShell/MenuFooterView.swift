import AppKit
import SwiftUI

struct MenuFooterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var showSettings

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            if let model = state.models.first(where: {
                $0.id == state.settings.activeModelID
            }) {
                Text(
                    state.settings.activeVoice.isEmpty
                        ? model.displayName
                        : "\(model.displayName) · \(state.settings.activeVoice)"
                )
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…", action: openSettingsWindow)
                .buttonStyle(.sayItInline)
            Button("Quit", action: state.quit)
                .buttonStyle(.sayItInline)
        }
        .font(.callout)
    }

    private func openSettingsWindow() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            WindowActivator.prepareForWindowPresentation()
            showSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
