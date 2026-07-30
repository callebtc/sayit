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
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Voice name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .disabled(isSaved)
                Spacer()
                Text(
                    "\(candidate.duration.formatted(.number.precision(.fractionLength(1)))) sec"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            VoiceFingerprintView(
                values: candidate.fingerprint,
                isActive: isPlayingThis
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)

            HStack(spacing: DesignTokens.standardSpacing) {
                Button(action: togglePlay) {
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace.offUp))
                }
                .buttonStyle(CircularIconButtonStyle(size: 30, prominent: isPlayingThis))
                .accessibilityLabel(isPlayingThis ? "Stop sample" : "Play sample")

                Spacer()

                Button(action: save) {
                    Label(
                        isSaved ? "Saved" : "Save Voice",
                        systemImage: isSaved ? "checkmark" : "plus"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(isSaved ? .green : nil)
                .disabled(isSaved || nameIsInvalid)
                .animation(DesignTokens.smoothAnimation, value: isSaved)
            }
        }
        .sayItCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice candidate \(name)")
    }

    private var isPlayingThis: Bool {
        state.voicePreview.isPlaying && state.voicePreview.playingID == candidate.id
    }

    private var nameIsInvalid: Bool {
        let count = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...50).contains(count)
    }

    private func togglePlay() {
        if isPlayingThis {
            state.voicePreview.stop()
        } else {
            state.playVoicePreview(candidate)
        }
    }

    private func save() {
        withAnimation(DesignTokens.springAnimation) {
            isSaved = true
        }
        state.saveVoiceCandidate(candidate, name: name)
    }
}
