import SwiftUI

struct HistoryRowView: View {
    let item: HistoryItemSnapshot

    var body: some View {
        HStack {
            Image(systemName: item.isPinned ? "pin.fill" : "waveform")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(item.title)
                    .lineLimit(1)
                HStack {
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
        .accessibilityElement(children: .combine)
    }
}
