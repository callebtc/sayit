import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state

    private var isActive: Bool {
        state.playback.state == .playing
            || state.playback.state == .preparing
            || state.playback.state == .buffering
    }

    var body: some View {
        icon
            .opacity(isActive ? 0.72 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
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
