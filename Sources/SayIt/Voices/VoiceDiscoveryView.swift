import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceDiscoveryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let model: ModelDescriptor
    @State private var sampleText: String
    @State private var characterPosition = 0.5
    @State private var surpriseMe = true

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
        .frame(width: 640, height: 600)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                .primary.opacity(0.05),
                in: .rect(cornerRadius: DesignTokens.rowCornerRadius)
            )

            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                HStack {
                    Text("Character")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(characterLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $characterPosition, in: 0...1)
                    .controlSize(.small)
                    .disabled(surpriseMe)
                    .accessibilityLabel("Voice character")
                    .accessibilityValue(characterLabel)
                HStack {
                    Text("Faithful")
                    Spacer()
                    Text("Expressive")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Toggle(
                    "Surprise me — random settings for every voice",
                    isOn: $surpriseMe
                )
                .toggleStyle(.checkbox)
                .font(.callout)
            }

            VoiceGenerationButton(
                title: candidates.isEmpty
                    ? "Generate Four Voices"
                    : "Generate Four More",
                systemImage: surpriseMe ? "dice" : "sparkles",
                generatingTitle: "Voicing the same sentence four ways…",
                isGenerating: isGenerating,
                completedCount: studio?.completedCount ?? 0,
                totalCount: studio?.totalCount ?? 4,
                isDisabled: sampleTextIsInvalid,
                action: generate,
                onCancel: state.cancelVoiceStudio
            )
        }
        .sayItCard()
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.standardSpacing) {
                ForEach(candidates) { candidate in
                    VoiceCandidateCard(candidate: candidate, model: model)
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
        let tuning = VoiceTuningSpace.interpolated(
            modelType: model.modelType,
            position: characterPosition
        )
        let candidateTunings: [VoiceTuning]? = surpriseMe
            ? (0..<4).map { _ in
                VoiceTuningSpace.randomized(modelType: model.modelType)
            }
            : nil
        state.startVoiceDiscovery(
            model: model,
            language: model.defaultLanguage,
            text: sampleText,
            tuning: tuning,
            candidateTunings: candidateTunings
        )
    }

    private var characterLabel: String {
        if surpriseMe { return "Random" }
        return switch VoiceTuningSpace.nearestPreset(
            position: characterPosition
        ) {
        case .faithful: "Faithful"
        case .natural: "Natural"
        case .expressive: "Expressive"
        }
    }
}
