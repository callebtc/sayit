import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool {
        state.playback.state == .playing
            || state.playback.state == .preparing
            || state.playback.state == .buffering
    }

    var body: some View {
        Group {
            if isActive, !reduceMotion {
                icon
                    .phaseAnimator([1.0, 0.4]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
            } else {
                icon
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.errorMessage != nil {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Say It")
        .accessibilityValue(state.statusText)
        .background {
            AppWindowCoordinator()
        }
    }

    private var icon: some View {
        Image("MenuBarIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 19, height: 19)
    }
}
