import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(
            systemName: state.errorMessage == nil
                ? "speaker.wave.2"
                : "speaker.wave.2.fill"
        )
        .symbolEffect(
            .variableColor.iterative,
            options: .repeating,
            isActive: !reduceMotion
                && (
                    state.playback.state == .playing
                        || state.playback.state == .preparing
                        || state.playback.state == .buffering
                )
        )
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
    }
}
