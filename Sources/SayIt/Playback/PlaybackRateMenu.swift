import SayItCore
import SwiftUI

struct PlaybackRateMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Menu {
            Button("Slower", systemImage: "minus") {
                adjustPlaybackRate(bySteps: -1)
            }
            .disabled(state.playback.rate <= PlaybackRate.minimum)

            Button("Faster", systemImage: "plus") {
                adjustPlaybackRate(bySteps: 1)
            }
            .disabled(state.playback.rate >= PlaybackRate.maximum)

            Divider()

            ForEach(menuRates, id: \.self) { rate in
                Button {
                    setPlaybackRate(rate)
                } label: {
                    if PlaybackRate.matches(state.playback.rate, rate) {
                        Label(
                            PlaybackRate.formatted(rate),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(PlaybackRate.formatted(rate))
                    }
                }
            }
        } label: {
            Text(PlaybackRate.formatted(state.playback.rate))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }

    /// Presets, plus the current rate when it was dialed in between them.
    private var menuRates: [Double] {
        let current = PlaybackRate.clamped(state.playback.rate)
        guard PlaybackRate.presets.allSatisfy({
            !PlaybackRate.matches($0, current)
        }) else {
            return PlaybackRate.presets
        }
        return (PlaybackRate.presets + [current]).sorted()
    }

    private func adjustPlaybackRate(bySteps steps: Int) {
        setPlaybackRate(
            PlaybackRate.adjusted(state.playback.rate, bySteps: steps)
        )
    }

    private func setPlaybackRate(_ rate: Double) {
        state.playback.rate = rate
        state.settings.playbackRate = rate
    }
}
