import SwiftUI

struct MenuFooterView: View {
    @Environment(AppState.self) private var state

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
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.plain)
            Divider()
                .frame(height: 16)
            Button("Quit", action: state.quit)
                .buttonStyle(.plain)
        }
        .font(.callout)
    }
}
