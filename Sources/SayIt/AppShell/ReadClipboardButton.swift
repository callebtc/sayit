import SwiftUI

struct ReadClipboardButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button(action: state.readClipboard) {
            HStack {
                Label("Read Clipboard", systemImage: "doc.on.clipboard")
                Spacer()
                Text(state.settings.globalShortcut.displayName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        .quaternary,
                        in: .rect(cornerRadius: 5)
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.sayItRow)
        .disabled(!state.isServiceOnline)
        .accessibilityHint(
            state.isServiceOnline
                ? "Reads the clipboard once and speaks its text locally"
                : "Unavailable until the background service connects"
        )
    }
}
