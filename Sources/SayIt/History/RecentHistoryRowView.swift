import SwiftUI

struct RecentHistoryRowView: View {
    @Environment(AppState.self) private var state
    let item: HistoryItemSnapshot

    var body: some View {
        Button(action: activateItem) {
            HStack(spacing: DesignTokens.compactSpacing) {
                Image(systemName: item.hasAudio ? "waveform" : "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(
                        item.createdAt,
                        format: .relative(presentation: .named)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if item.duration > 0 {
                    Text(item.duration.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(
                    systemName: item.hasAudio
                        ? "play.circle.fill"
                        : "arrow.clockwise.circle"
                )
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .contentShape(.rect)
            .frame(
                maxWidth: .infinity,
                minHeight: DesignTokens.minimumControlSize,
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .disabled(!state.isServiceOnline)
    }

    private var accessibilityLabel: String {
        if item.hasAudio {
            "Play \(item.title)"
        } else {
            "Regenerate \(item.title)"
        }
    }

    private var accessibilityHint: String {
        if item.hasAudio {
            "Loads this recording into the player and starts playback"
        } else {
            "Generates this speech again and starts playback"
        }
    }

    private func activateItem() {
        if item.hasAudio {
            state.replay(item)
        } else {
            state.regenerate(item)
        }
    }
}
