import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceSelectionPicker: View {
    @Binding var selection: VoiceSelection
    let model: ModelDescriptor
    let profiles: [VoiceProfileSnapshot]

    var body: some View {
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
    }
}
