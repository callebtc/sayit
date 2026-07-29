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
            } else if let progress = state.downloadProgress {
                Divider()
                DownloadStatusView(progress: progress)
                    .padding(DesignTokens.generousSpacing)
            } else if let error = state.errorMessage {
                Divider()
                ErrorStatusView(message: error)
                    .padding(DesignTokens.generousSpacing)
            } else if state.needsLongTextConfirmation {
                Divider()
                LongTextConfirmationView()
                    .padding(DesignTokens.generousSpacing)
            } else if state.playback.state != .idle {
                Divider()
                PlaybackSectionView()
                    .padding(.horizontal, DesignTokens.generousSpacing)
                    .padding(.bottom, DesignTokens.compactSpacing)
                SpeechLyricsView(
                    text: state.playback.spokenText,
                    chunks: state.playback.spokenChunks,
                    elapsed: state.playback.elapsed,
                    generatedDuration: state.playback.generatedDuration
                )
                .frame(height: 150)
                .padding(.horizontal, DesignTokens.generousSpacing)
                .padding(.bottom, DesignTokens.compactSpacing)
            } else {
                Divider()
                ReadClipboardButton()
                    .padding(.horizontal, DesignTokens.compactSpacing)
                    .padding(.vertical, 6)

                Divider()
                RecentHistoryView()
                    .padding(DesignTokens.generousSpacing)
            }

            Divider()
            MenuFooterView()
                .padding(.horizontal, DesignTokens.generousSpacing)
                .padding(.vertical, DesignTokens.compactSpacing)
        }
        .frame(width: DesignTokens.popoverWidth)
    }
}
