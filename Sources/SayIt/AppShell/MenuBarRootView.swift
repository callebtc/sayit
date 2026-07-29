import SwiftUI

struct MenuBarRootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            StatusHeaderView()
                .padding(DesignTokens.generousSpacing)

            if let progress = state.downloadProgress {
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
                PlaybackSectionView()
                    .padding(.horizontal, DesignTokens.generousSpacing)
                    .padding(.bottom, DesignTokens.generousSpacing)
            }

            Divider()
            ReadClipboardButton()
                .padding(.horizontal, DesignTokens.standardSpacing)
                .padding(.vertical, DesignTokens.compactSpacing)

            Divider()
            RecentHistoryView()
                .padding(DesignTokens.generousSpacing)

            Divider()
            MenuFooterView()
                .padding(.horizontal, DesignTokens.standardSpacing)
                .padding(.vertical, DesignTokens.compactSpacing)
        }
        .frame(width: DesignTokens.popoverWidth)
        .sheet(isPresented: $state.isShowingOnboarding) {
            OnboardingView()
                .environment(state)
        }
    }
}
