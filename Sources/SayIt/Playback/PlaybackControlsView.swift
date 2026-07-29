import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            PlaybackRateMenu()

            Spacer()

            HStack(spacing: DesignTokens.generousSpacing) {
                Button(
                    "Back \(Int(state.settings.rewindInterval)) seconds",
                    systemImage: "gobackward.\(Int(state.settings.rewindInterval))",
                    action: skipBackward
                )
                .labelStyle(.iconOnly)
                .buttonStyle(CircularIconButtonStyle())

                Button(
                    state.playback.state == .playing ? "Pause" : "Play",
                    systemImage: state.playback.state == .playing
                        ? "pause.fill"
                        : "play.fill",
                    action: togglePlayback
                )
                .labelStyle(.iconOnly)
                .buttonStyle(CircularIconButtonStyle(size: 36, prominent: true))

                Button(
                    "Forward \(Int(state.settings.forwardInterval)) seconds",
                    systemImage: "goforward.\(Int(state.settings.forwardInterval))",
                    action: skipForward
                )
                .labelStyle(.iconOnly)
                .buttonStyle(CircularIconButtonStyle())
            }

            Spacer()

            Button(
                "Clear",
                systemImage: "xmark",
                action: state.clearCurrentSpeech
            )
            .labelStyle(.iconOnly)
            .buttonStyle(CircularIconButtonStyle())
        }
        .disabled(!state.isServiceOnline)
        .accessibilityHint(
            state.isServiceOnline
                ? ""
                : "Playback is unavailable until the background service connects"
        )
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
