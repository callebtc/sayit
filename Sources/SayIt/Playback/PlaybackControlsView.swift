import SayItCore
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(AppState.self) private var state
    @State private var volumeControlActive = false
    @State private var speedControlActive = false

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

                    Button {
                        speedControlActive = true
                    } label: {
                        Label(
                            PlaybackRate.formatted(state.playback.rate),
                            systemImage: "timer"
                        )
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .background(.primary.opacity(0.07), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(PlaybackRate.formatted(state.playback.rate))
                    .help("Playback speed")
                    .onHover { hovering in
                        if hovering {
                            speedControlActive = true
                        }
                    }

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
            .opacity(volumeControlActive || speedControlActive ? 0 : 1)
            .allowsHitTesting(!volumeControlActive && !speedControlActive)
            .accessibilityHidden(volumeControlActive || speedControlActive)

            VolumeControlView(isActive: $volumeControlActive)
                .opacity(volumeControlActive ? 1 : 0)
                .allowsHitTesting(volumeControlActive)
                .accessibilityHidden(!volumeControlActive)

            PlaybackRateControlView(isActive: $speedControlActive)
                .opacity(speedControlActive ? 1 : 0)
                .allowsHitTesting(speedControlActive)
                .accessibilityHidden(!speedControlActive)
        }
        .onHover { hovering in
            if !hovering {
                volumeControlActive = false
                speedControlActive = false
            }
        }
        .animation(DesignTokens.springAnimation, value: state.clipboardHasNewText)
        .animation(DesignTokens.springAnimation, value: volumeControlActive)
        .animation(DesignTokens.springAnimation, value: speedControlActive)
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
