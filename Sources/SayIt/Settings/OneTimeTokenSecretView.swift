import AppKit
import SwiftUI

struct OneTimeTokenSecretView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Token created", systemImage: "checkmark.circle.fill")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            Text("Copy this secret now. It cannot be displayed again.")
                .foregroundStyle(.secondary)

            Text(state.oneTimeTokenSecret ?? "")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(DesignTokens.standardSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.55),
                    in: .rect(cornerRadius: DesignTokens.cardCornerRadius)
                )

            HStack {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Done", action: state.dismissOneTimeToken)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func copy() {
        guard let secret = state.oneTimeTokenSecret else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)
    }
}
