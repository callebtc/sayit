import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var playback = state.playback

        HStack {
            Button(
                "Back \(Int(state.settings.rewindInterval)) seconds",
                systemImage: "gobackward.\(Int(state.settings.rewindInterval))"
            ) {
                state.playback.skip(by: -state.settings.rewindInterval)
            }
            .labelStyle(.iconOnly)
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
            .controlSize(.large)
        }

        HStack {
            Picker("Playback rate", selection: $playback.rate) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                    Text(rate, format: .number.precision(.fractionLength(0...2)))
                        .tag(rate)
                }
            }
            .labelsHidden()
            .frame(width: 86)
            .onChange(of: playback.rate) { _, newRate in
                state.settings.playbackRate = newRate
            }
            Spacer()
            Button("Stop") {
                state.cancelCurrentRequest()
            }
        }
    }
}
