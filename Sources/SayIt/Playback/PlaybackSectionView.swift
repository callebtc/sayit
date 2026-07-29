import SwiftUI

struct PlaybackSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            VoiceRibbonView(
                amplitudes: state.playback.amplitudes,
                elapsed: state.playback.elapsed,
                generatedDuration: state.playback.generatedDuration,
                estimatedDuration: state.playback.estimatedDuration,
                onSeek: state.playback.seek
            )
            PlaybackControlsView()
        }
    }
}
