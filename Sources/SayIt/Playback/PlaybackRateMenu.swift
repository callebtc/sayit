import SwiftUI

struct PlaybackRateMenu: View {
    @Environment(AppState.self) private var state

    private let playbackRates = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Menu {
            ForEach(playbackRates, id: \.self) { rate in
                Button {
                    setPlaybackRate(rate)
                } label: {
                    if state.playback.rate == rate {
                        Label(formattedRate(rate), systemImage: "checkmark")
                    } else {
                        Text(formattedRate(rate))
                    }
                }
            }
        } label: {
            Label(
                formattedRate(state.playback.rate),
                systemImage: "speedometer"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }

    private func setPlaybackRate(_ rate: Double) {
        state.playback.rate = rate
        state.settings.playbackRate = rate
    }

    private func formattedRate(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
