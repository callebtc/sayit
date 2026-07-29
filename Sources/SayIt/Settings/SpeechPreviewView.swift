import SayItCore
import SwiftUI

struct SpeechPreviewView: View {
    @Environment(AppState.self) private var state
    @State private var sampleText =
        "Say It turns the words on your Mac into calm, private audio."

    var body: some View {
        GroupBox("Voice Preview") {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                TextField(
                    "Sample sentence",
                    text: $sampleText,
                    axis: .vertical
                )
                .lineLimit(2...4)

                HStack {
                    Text("Uses the model, voice, language, and speed selected above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(
                        "Test Voice",
                        systemImage: "speaker.wave.2.fill",
                        action: testVoice
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(!canTestVoice)
                }

                if state.playback.state != .idle {
                    Divider()
                    PlaybackSectionView()
                }
            }
            .padding(DesignTokens.compactSpacing)
        }
    }

    private var canTestVoice: Bool {
        !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.installedModelIDs.contains(state.settings.activeModelID)
    }

    private func testVoice() {
        state.speakSample(sampleText)
    }
}
