import SwiftUI

struct RecentHistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if state.history.items.isEmpty {
                Text("Spoken items appear here.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: DesignTokens.minimumControlSize)
            } else {
                ForEach(state.history.items.prefix(3)) { item in
                    HStack {
                        Image(
                            systemName: item.state == .completed
                                ? "waveform"
                                : "arrow.clockwise"
                        )
                        VStack(alignment: .leading) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.createdAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.duration > 0 {
                            Text(item.duration.formattedDuration)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: DesignTokens.minimumControlSize)
                }
            }

            Button("View All History…") {
                openWindow(id: "history")
            }
            .buttonStyle(.link)
        }
    }
}
