import SwiftUI

struct HistoryRowView: View {
    let item: HistoryItemSnapshot

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            Image(systemName: item.isPinned ? "pin.fill" : "waveform")
                .foregroundStyle(item.isPinned ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.createdAt, format: .relative(presentation: .named))
                    if item.duration > 0 {
                        Text("·")
                        Text(item.duration.formattedDuration)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
