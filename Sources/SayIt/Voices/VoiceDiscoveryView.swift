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
        VStack(alignment: .leading, spacing: DesignTokens.generousSpacing) {
            header

            setupCard

            if let error = studio?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            Group {
                if candidates.isEmpty, isGenerating {
                    VStack(spacing: DesignTokens.standardSpacing) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Voicing the same sentence four ways…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else if candidates.isEmpty, !isGenerating {
                    ContentUnavailableView(
                        "Ready to Listen",
                        systemImage: "waveform.badge.plus",
                        description: Text(
                            "Generate a batch, compare the same sentence, and keep your favorites."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    candidateList
                }
            }
            .animation(
                DesignTokens.smoothAnimation,
                value: candidates.isEmpty || isGenerating
            )
        }
        .padding(DesignTokens.generousSpacing)
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(isGenerating)
        .onDisappear(perform: state.cancelVoiceStudio)
        .animation(DesignTokens.smoothAnimation, value: studio?.errorMessage)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Discover \(model.displayName) Voices")
                    .font(.title2.weight(.semibold))
                Text(
                    "Each sample starts from a fresh voice. Save only the ones you want to keep."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            TextField(
                "Comparison text",
                text: $sampleText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.plain)

            Picker("Character", selection: $tuningPreset) {
                ForEach(VoiceTuningPreset.allCases, id: \.self) {
                    Text(label(for: $0)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: DesignTokens.standardSpacing) {
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
                    .frame(maxWidth: 160)
                    Button("Cancel", role: .cancel, action: state.cancelVoiceStudio)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(DesignTokens.smoothAnimation, value: isGenerating)
        }
        .sayItCard()
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.standardSpacing) {
                ForEach(candidates) { candidate in
                    VoiceCandidateCard(candidate: candidate)
                        .transition(
                            .opacity
                                .combined(with: .scale(scale: 0.96))
                                .combined(with: .move(edge: .bottom))
                        )
                }
            }
            .padding(1)
            .animation(DesignTokens.springAnimation, value: candidates.count)
        }
        .scrollIndicators(.never)
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
