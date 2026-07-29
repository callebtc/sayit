import SwiftUI

struct ReadClipboardButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button(action: state.readClipboard) {
            HStack {
                Label("Read Clipboard", systemImage: "doc.on.clipboard")
                Spacer()
                Text(state.settings.globalShortcut.displayName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!state.isServiceOnline)
        .frame(minHeight: DesignTokens.minimumControlSize)
        .accessibilityHint(
            state.isServiceOnline
                ? "Reads the clipboard once and speaks its text locally"
                : "Unavailable until the background service connects"
        )
    }
}
