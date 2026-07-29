import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            playbackRateMenu

            Button(
                "Back \(Int(state.settings.rewindInterval)) seconds",
                systemImage: "gobackward.\(Int(state.settings.rewindInterval))"
            ) {
                state.playback.skip(by: -state.settings.rewindInterval)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .controlSize(.large)

            Spacer()

            Button(
                state.playback.state == .playing ? "Pause" : "Play",
                systemImage: state.playback.state == .playing
                    ? "pause.fill"
                    : "play.fill"
            ) {
                if state.playback.state == .playing {
                    state.playback.pause()
                } else {
                    state.playback.play()
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            Button(
                "Forward \(Int(state.settings.forwardInterval)) seconds",
                systemImage: "goforward.\(Int(state.settings.forwardInterval))"
            ) {
                state.playback.skip(by: state.settings.forwardInterval)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .controlSize(.large)

            Button(
                "Clear",
                systemImage: "xmark",
                action: state.clearCurrentSpeech
            )
            .buttonStyle(.plain)
        }
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
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
