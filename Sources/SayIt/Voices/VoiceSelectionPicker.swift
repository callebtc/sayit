import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceSelectionPicker: View {
    @Environment(AppState.self) private var state

    @Binding var selection: VoiceSelection
    let model: ModelDescriptor
    let profiles: [VoiceProfileSnapshot]

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            Picker("Voice", selection: $selection) {
                if !model.capabilities.supportsRandomVoiceSampling {
                    Text("Automatic")
                        .tag(VoiceSelection.automaticStable)
                }

                ForEach(model.voices, id: \.self) { voice in
                    Text(voice)
                        .tag(VoiceSelection.preset(voice))
                }

                ForEach(profiles) { profile in
                    Text(profile.displayName)
                        .tag(VoiceSelection.profile(profile.id))
                }

                if model.capabilities.supportsRandomVoiceSampling {
                    Divider()
                    Text("Random voice")
                        .tag(VoiceSelection.automaticStable)
                    Text("Random voice every paragraph")
                        .tag(VoiceSelection.randomPerParagraph)
                }
            }

            Button(action: togglePreview) {
                Image(systemName: isPreviewBusy ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace.offUp))
            }
            .buttonStyle(
                CircularIconButtonStyle(size: 26, prominent: isPreviewBusy)
            )
            .disabled(!canPreview)
            .help(
                canPreview
                    ? "Preview the selected voice"
                    : "Install the model to preview its voices"
            )
            .accessibilityLabel(
                isPreviewBusy ? "Stop voice preview" : "Preview selected voice"
            )
        }
    }

    private var isPreviewBusy: Bool {
        [
            PlaybackState.preparing,
            .buffering,
            .playing
        ].contains(state.playback.state)
    }

    private var canPreview: Bool {
        state.installedModelIDs.contains(model.id) && state.isServiceOnline
    }

    private func togglePreview() {
        if isPreviewBusy {
            state.clearCurrentSpeech()
        } else {
            state.previewVoiceSelection(selection, model: model)
        }
    }
}
