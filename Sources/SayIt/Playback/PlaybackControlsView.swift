import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            PlaybackRateMenu()

            Button(
                "Back \(Int(state.settings.rewindInterval)) seconds",
                systemImage: "gobackward.\(Int(state.settings.rewindInterval))",
                action: skipBackward
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .controlSize(.large)

            Spacer()

            Button(
                state.playback.state == .playing ? "Pause" : "Play",
                systemImage: state.playback.state == .playing
                    ? "pause.fill"
                    : "play.fill",
                action: togglePlayback
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            Button(
                "Forward \(Int(state.settings.forwardInterval)) seconds",
                systemImage: "goforward.\(Int(state.settings.forwardInterval))",
                action: skipForward
            )
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

    private func skipBackward() {
        state.playback.skip(by: -state.settings.rewindInterval)
    }

    private func togglePlayback() {
        if state.playback.state == .playing {
            state.playback.pause()
        } else {
            state.playback.play()
        }
    }

    private func skipForward() {
        state.playback.skip(by: state.settings.forwardInterval)
    }
}
