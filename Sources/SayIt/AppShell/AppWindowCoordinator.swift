import AppKit
import SwiftUI

struct AppWindowCoordinator: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(
                of: state.isShowingOnboarding,
                initial: true,
                openOnboardingIfNeeded
            )
    }

    private func openOnboardingIfNeeded(
        oldValue: Bool,
        newValue: Bool
    ) {
        _ = oldValue
        guard newValue else { return }
        openWindow(id: AppWindowID.onboarding)
        NSApp.activate()
    }
}
