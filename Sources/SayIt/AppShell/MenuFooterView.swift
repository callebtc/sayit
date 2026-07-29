import AppKit
import SwiftUI

struct MenuFooterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var showSettings

    var body: some View {
        HStack {
            if let model = state.models.first(where: {
                $0.id == state.settings.activeModelID
            }) {
                Text(
                    state.settings.activeVoice.isEmpty
                        ? model.displayName
                        : "\(model.displayName) · \(state.settings.activeVoice)"
                )
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…", action: openSettingsWindow)
            .buttonStyle(.plain)
            Divider()
                .frame(height: 16)
            Button("Quit", action: state.quit)
                .buttonStyle(.plain)
        }
        .font(.callout)
    }

    private func openSettingsWindow() {
        dismiss()
        showSettings()
        NSApp.activate()
    }
}
