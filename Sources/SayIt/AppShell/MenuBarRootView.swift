import SwiftUI

struct MenuBarRootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeaderView()
                .padding(DesignTokens.generousSpacing)

            if state.serviceConnection.showsRepair {
                Divider()
                ServiceRepairView()
                    .padding(DesignTokens.generousSpacing)
                    .transition(.opacity)
            } else if let progress = state.downloadProgress {
                Divider()
                DownloadStatusView(progress: progress)
                    .padding(DesignTokens.generousSpacing)
                    .transition(.opacity)
            } else if let error = state.errorMessage {
                Divider()
                ErrorStatusView(message: error)
                    .padding(DesignTokens.generousSpacing)
                    .transition(.opacity)
            } else if state.needsLongTextConfirmation {
                Divider()
                LongTextConfirmationView()
                    .padding(DesignTokens.generousSpacing)
                    .transition(.opacity)
            } else if state.playback.state != .idle {
                Divider()
                PlaybackSectionView()
                    .padding(.horizontal, DesignTokens.generousSpacing)
                    .padding(.bottom, DesignTokens.compactSpacing)
                SpeechLyricsView(
                    text: state.playback.spokenText,
                    chunks: state.playback.spokenChunks,
                    elapsed: state.playback.elapsed,
                    generatedDuration: state.playback.generatedDuration,
                    onSeek: state.playback.seek
                )
                .frame(height: 150)
                .padding(.horizontal, DesignTokens.generousSpacing)
                .padding(.bottom, DesignTokens.compactSpacing)
                .transition(.opacity)
            } else {
                Divider()
                ReadClipboardButton()
                    .padding(.horizontal, DesignTokens.compactSpacing)
                    .padding(.vertical, 6)

                Divider()
                RecentHistoryView()
                    .padding(DesignTokens.generousSpacing)
                    .transition(.opacity)
            }

            Divider()
            MenuFooterView()
                .padding(.horizontal, DesignTokens.generousSpacing)
                .padding(.vertical, DesignTokens.compactSpacing)
        }
        .frame(width: DesignTokens.popoverWidth)
        .animation(.smooth(duration: 0.3), value: section)
    }

    private var section: Int {
        if state.serviceConnection.showsRepair { return 1 }
        if state.downloadProgress != nil { return 2 }
        if state.errorMessage != nil { return 3 }
        if state.needsLongTextConfirmation { return 4 }
        if state.playback.state != .idle { return 5 }
        return 6
    }
}
