import SwiftUI

struct PlaybackSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            if !state.currentChunkPreview.isEmpty {
                Text(state.currentChunkPreview)
                    .font(.body)
                    .fontDesign(.rounded)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            VoiceRibbonView(
                amplitudes: state.playback.amplitudes,
                elapsed: state.playback.elapsed,
                generatedDuration: state.playback.generatedDuration,
                estimatedDuration: state.playback.estimatedDuration,
                onSeek: state.playback.seek
            )
            PlaybackControlsView()
        }
        .animation(
            DesignTokens.quickAnimation,
            value: state.currentChunkPreview
        )
    }
}
