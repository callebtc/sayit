import SayItProtocol
import SwiftUI

struct VoiceCandidateCard: View {
    @Environment(AppState.self) private var state
    let candidate: VoiceCandidateSnapshot

    @State private var name: String
    @State private var isSaved = false

    init(candidate: VoiceCandidateSnapshot) {
        self.candidate = candidate
        _name = State(initialValue: candidate.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VoiceFingerprintView(values: candidate.fingerprint)
                Spacer()
                Text(
                    candidate.duration,
                    format: .number.precision(.fractionLength(1))
                )
                Text("sec")
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Voice name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button(
                    "Play Sample",
                    systemImage: "play.fill",
                    action: play
                )
                Button(
                    isSaved ? "Saved" : "Save Voice",
                    systemImage: isSaved ? "checkmark" : "plus",
                    action: save
                )
                .buttonStyle(.borderedProminent)
                .disabled(isSaved || nameIsInvalid)
            }
        }
        .padding()
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice candidate \(name)")
    }

    private var nameIsInvalid: Bool {
        let count = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...50).contains(count)
    }

    private func play() {
        state.playVoicePreview(candidate)
    }

    private func save() {
        state.saveVoiceCandidate(candidate, name: name)
        isSaved = true
    }
}
