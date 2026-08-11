import SayItCore
import SwiftUI

struct SpeechPreviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            TextField(
                "Sample sentence",
                text: $settings.voicePreviewSample,
                axis: .vertical
            )
            .lineLimit(2...4)

            HStack(alignment: .center) {
                Text(
                    "Speaking pace is generated into new audio. Playback speed changes listening instantly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(
                    "Test Voice",
                    systemImage: state.playback.state == .playing
                        ? "speaker.wave.2.fill"
                        : "speaker.wave.2",
                    action: testVoice
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canTestVoice)
            }

            if state.playback.state != .idle {
                Divider()
                PlaybackSectionView(
                    isPresented: state.isAppWindowPresented
                )
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .animation(
            DesignTokens.smoothAnimation,
            value: state.playback.state != .idle
        )
    }

    private var canTestVoice: Bool {
        !state.settings.voicePreviewSample.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && state.installedModelIDs.contains(state.settings.activeModelID)
            && state.isServiceOnline
    }

    private func testVoice() {
        state.speakSample(state.settings.voicePreviewSample)
    }
}
