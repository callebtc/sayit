import SwiftUI

struct MenuBarRootView: View {
    @Environment(AppState.self) private var state
    private let clipboardTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeaderView()
                .padding(DesignTokens.generousSpacing)

            if state.serviceConnection.showsRepair {
                Divider()
                ServiceRepairView()
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
                    showsHighlight: state.playback.state == .playing
                        || state.playback.state == .paused
                        || state.playback.state == .finished,
                    showsBlockSeparators:
                        state.settings.showLyricsBlockSeparators,
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
        .onAppear(perform: state.refreshClipboardState)
        .onReceive(clipboardTimer) { _ in
            state.refreshClipboardState()
        }
    }

    private var section: Int {
        if state.serviceConnection.showsRepair { return 1 }
        if state.errorMessage != nil { return 2 }
        if state.needsLongTextConfirmation { return 3 }
        if state.playback.state != .idle { return 4 }
        return 5
    }
}
