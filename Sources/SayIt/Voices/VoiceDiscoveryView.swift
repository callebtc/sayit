import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceDiscoveryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let model: ModelDescriptor
    @State private var sampleText: String
    @State private var tuningPreset = VoiceTuningPreset.natural

    init(model: ModelDescriptor) {
        self.model = model
        _sampleText = State(
            initialValue: VoiceSampleText.discovery(
                language: model.defaultLanguage
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Discover \(model.displayName) Voices")
                        .font(.title2)
                        .bold()
                    Text(
                        "Each sample starts from a fresh voice. Save only the ones you want to keep."
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
            }

            TextField(
                "Comparison text",
                text: $sampleText,
                axis: .vertical
            )
            .lineLimit(2...5)

            Picker("Character", selection: $tuningPreset) {
                ForEach(VoiceTuningPreset.allCases, id: \.self) {
                    Text(label(for: $0)).tag($0)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button(
                    candidates.isEmpty
                        ? "Generate Four Voices"
                        : "Generate Four More",
                    systemImage: "sparkles",
                    action: generate
                )
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || sampleTextIsInvalid)

                if isGenerating {
                    ProgressView(
                        value: Double(studio?.completedCount ?? 0),
                        total: Double(studio?.totalCount ?? 4)
                    )
                    .frame(maxWidth: 220)
                    Button("Cancel", role: .cancel, action: state.cancelVoiceStudio)
                }
            }

            if let error = studio?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if candidates.isEmpty, !isGenerating {
                ContentUnavailableView(
                    "Ready to Listen",
                    systemImage: "waveform.badge.plus",
                    description: Text(
                        "Generate a batch, compare the same sentence, and keep your favorites."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack {
                        ForEach(candidates) { candidate in
                            VoiceCandidateCard(candidate: candidate)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
        .interactiveDismissDisabled(isGenerating)
        .onDisappear(perform: state.cancelVoiceStudio)
    }

    private var studio: VoiceStudioSnapshot? {
        guard state.voiceStudio?.modelID == model.id.rawValue else {
            return nil
        }
        return state.voiceStudio
    }

    private var candidates: [VoiceCandidateSnapshot] {
        studio?.candidates ?? []
    }

    private var isGenerating: Bool {
        studio?.state == .generating
    }

    private var sampleTextIsInvalid: Bool {
        let count = sampleText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...500).contains(count)
    }

    private func generate() {
        state.startVoiceDiscovery(
            model: model,
            language: model.defaultLanguage,
            text: sampleText,
            tuning: VoiceTuning(preset: tuningPreset)
        )
    }

    private func label(for preset: VoiceTuningPreset) -> String {
        switch preset {
        case .faithful: "Faithful"
        case .natural: "Natural"
        case .expressive: "Expressive"
        }
    }
}
