import AppKit
import SwiftUI

struct OneTimeTokenSecretView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Token created", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)

            Text(
                "Copy this secret now. It cannot be displayed again."
            )
            Text(state.oneTimeTokenSecret ?? "")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            HStack {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Done", action: state.dismissOneTimeToken)
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
