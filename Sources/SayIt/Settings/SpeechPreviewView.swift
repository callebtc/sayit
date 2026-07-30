import SayItCore
import SwiftUI

struct SpeechPreviewView: View {
    @Environment(AppState.self) private var state
    @State private var sampleText =
        "Say It turns the words on your Mac into calm, private audio."

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            TextField(
                "Sample sentence",
                text: $sampleText,
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
                PlaybackSectionView()
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
        !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.installedModelIDs.contains(state.settings.activeModelID)
            && state.isServiceOnline
    }

    private func testVoice() {
        state.speakSample(sampleText)
    }
}
