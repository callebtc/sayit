import SayItCore
import SwiftUI

struct PlaybackRateControlView: View {
    @Environment(AppState.self) private var state
    @Binding var isActive: Bool

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            Image(systemName: "timer")
                .font(.system(size: 28 * 0.44, weight: .semibold))
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(.primary.opacity(0.07))
                }
                .accessibilityHidden(true)

            Text("Playback speed")
                .frame(width: 104, alignment: .leading)

            Slider(
                value: playbackRate,
                in: PlaybackRate.minimum...PlaybackRate.maximum,
                step: 0.1
            ) {
                Text("Playback speed")
            }
            .labelsHidden()
            .accessibilityValue(PlaybackRate.formatted(state.playback.rate))

            Text(PlaybackRate.formatted(state.playback.rate))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .contentShape(.rect)
        .onExitCommand {
            isActive = false
        }
        .help("Playback speed")
    }

    private var playbackRate: Binding<Double> {
        Binding(
            get: { state.playback.rate },
            set: { rate in
                let normalized = PlaybackRate.normalized(rate)
                state.playback.rate = normalized
                state.settings.playbackRate = normalized
            }
        )
    }
}
