import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state
    @State private var volumeControlActive = false

    var body: some View {
        ZStack {
            Group {
                HStack(spacing: DesignTokens.generousSpacing) {
                    Button(
                        "Back \(Int(state.settings.rewindInterval)) seconds",
                        systemImage: "gobackward.\(Int(state.settings.rewindInterval))",
                        action: skipBackward
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircularIconButtonStyle())

                    Button(action: togglePlayback) {
                        Image(
                            systemName: state.playback.state == .playing
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .contentTransition(.symbolEffect(.replace.offUp))
                    }
                    .accessibilityLabel(state.playback.state == .playing ? "Pause" : "Play")
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

                HStack(spacing: DesignTokens.compactSpacing) {
                    Button {
                        volumeControlActive = true
                    } label: {
                        Image(
                            systemName: VolumeControlView.symbol(
                                for: state.playback.volume
                            )
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircularIconButtonStyle())
                    .accessibilityLabel("Playback volume")
                    .help("Playback volume")
                    .onHover { hovering in
                        if hovering {
                            volumeControlActive = true
                        }
                    }

                    PlaybackRateMenu()

                    Spacer()

                    if state.clipboardHasNewText {
                        Button(
                            "Read Clipboard",
                            systemImage: "doc.on.clipboard",
                            action: state.readClipboard
                        )
                        .labelStyle(.iconOnly)
                        .buttonStyle(CircularIconButtonStyle())
                        .help("Clear this and read the clipboard instead")
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    }

                    Button(
                        "Clear",
                        systemImage: "xmark",
                        action: state.clearCurrentSpeech
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircularIconButtonStyle())
                }
            }
            .opacity(volumeControlActive ? 0 : 1)
            .allowsHitTesting(!volumeControlActive)

            VolumeControlView(isActive: $volumeControlActive)
                .opacity(volumeControlActive ? 1 : 0)
                .allowsHitTesting(volumeControlActive)
        }
        .onHover { hovering in
            if !hovering {
                volumeControlActive = false
            }
        }
        .animation(DesignTokens.springAnimation, value: state.clipboardHasNewText)
        .animation(DesignTokens.springAnimation, value: volumeControlActive)
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
