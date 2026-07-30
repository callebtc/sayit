import SwiftUI

struct PlaybackSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            if state.playback.state == .preparing {
                HStack(spacing: DesignTokens.compactSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing speech…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.ribbonHeight + 13)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            } else {
                VoiceRibbonView(
                    amplitudes: state.playback.amplitudes,
                    elapsed: state.playback.elapsed,
                    generatedDuration: state.playback.generatedDuration,
                    estimatedDuration: state.playback.estimatedDuration,
                    isPlaying: state.playback.state == .playing,
                    isBuffering: state.playback.state == .buffering,
                    onSeek: state.playback.seek
                )
                .transition(.opacity)
            }
            PlaybackControlsView()
        }
        .animation(.smooth(duration: 0.3), value: state.playback.state == .preparing)
    }
}
