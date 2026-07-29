import SayItProtocol
import SwiftUI

struct APITokenRow: View {
    let token: APITokenMetadata
    let onRevoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(token.name)
                Text("\(token.prefix)… · \(scopeSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Created \(token.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive, action: onRevoke)
        }
        .accessibilityElement(children: .contain)
    }

    private var scopeSummary: String {
        if token.scopes == APITokenPreset.fullAccess.scopes {
            return "Full access"
        }
        if token.scopes == APITokenPreset.speechControl.scopes {
            return "Speech control"
        }
        if token.scopes == APITokenPreset.readOnly.scopes {
            return "Read only"
        }
        return "\(token.scopes.count) custom scopes"
    }
}
