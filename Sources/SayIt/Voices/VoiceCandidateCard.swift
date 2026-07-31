import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceCandidateCard: View {
    @Environment(AppState.self) private var state
    let candidate: VoiceCandidateSnapshot
    let model: ModelDescriptor

    @State private var name: String
    @State private var tuning: VoiceTuning
    @State private var isSaved = false
    @State private var showsAdjustments = false
    @State private var isRerolling = false

    init(candidate: VoiceCandidateSnapshot, model: ModelDescriptor) {
        self.candidate = candidate
        self.model = model
        _name = State(initialValue: candidate.suggestedName)
        _tuning = State(initialValue: candidate.tuning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Voice name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        .primary.opacity(isSaved ? 0 : 0.05),
                        in: .rect(cornerRadius: DesignTokens.rowCornerRadius)
                    )
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

            Text(parameterSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(parameterSummary)

            HStack(spacing: DesignTokens.compactSpacing) {
                Button {
                    showsAdjustments.toggle()
                } label: {
                    HStack(spacing: DesignTokens.compactSpacing) {
                        Text("Adjust")
                            .font(.callout.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(
                                .degrees(showsAdjustments ? 0 : -90)
                            )
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Spacer()
                if showsAdjustments {
                    Button(
                        "Re-roll",
                        systemImage: "dice",
                        action: reroll
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircularIconButtonStyle(size: 26))
                    .disabled(isRerolling || isGenerating)
                    .help("Re-roll with these settings")
                    .accessibilityHint(
                        "Generates a fresh voice with these settings"
                    )
                }
            }

            if showsAdjustments {
                VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                    ForEach(parameters, id: \.key) { parameter in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(parameter.title)
                                    .font(.callout)
                                Spacer()
                                Text(
                                    value(parameter.key).formatted(
                                        .number.precision(.fractionLength(
                                            parameter.step >= 1 ? 0 : 2
                                        ))
                                    )
                                )
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: binding(parameter.key),
                                in: parameter.range,
                                step: parameter.step
                            )
                            .controlSize(.small)
                            .accessibilityLabel(parameter.title)
                        }
                    }
                    Label(
                        "Re-roll creates a fresh voice with these settings. Save keeps this voice and applies them to future speech.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, DesignTokens.compactSpacing)
            }

            HStack(spacing: DesignTokens.standardSpacing) {
                Button(action: togglePlay) {
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace.offUp))
                }
                .buttonStyle(CircularIconButtonStyle(size: 30, prominent: isPlayingThis))
                .accessibilityLabel(isPlayingThis ? "Stop sample" : "Play sample")

                if isRerolling {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(action: save) {
                    Label(
                        isSaved ? "Saved" : "Save Voice",
                        systemImage: isSaved ? "checkmark" : "plus"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSaved ? .secondary : Color.accentColor)
                }
                .buttonStyle(.sayItInline)
                .disabled(isSaved || nameIsInvalid)
            }
        }
        .sayItCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice candidate \(name)")
        .onChange(of: candidate.tuning) {
            tuning = candidate.tuning
        }
    }

    private var parameters: [VoiceTuningParameter] {
        VoiceTuningSpace.parameters(modelType: model.modelType)
    }

    private var parameterSummary: String {
        parameters.map { parameter in
            let value = tuning.parameters[parameter.key]
                ?? parameter.range.lowerBound
            return "\(parameter.title) \(value.formatted(.number.precision(.fractionLength(parameter.step >= 1 ? 0 : 2))))"
        }
        .joined(separator: " · ")
    }

    private var isPlayingThis: Bool {
        state.voicePreview.isPlaying && state.voicePreview.playingID == candidate.id
    }

    private var isGenerating: Bool {
        state.voiceStudio?.state == .generating
    }

    private var nameIsInvalid: Bool {
        let count = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...50).contains(count)
    }

    private func binding(_ key: String) -> Binding<Double> {
        Binding(
            get: {
                tuning.parameters[key]
                    ?? VoiceTuningSpace.ranges(modelType: model.modelType)[key]?.lowerBound
                    ?? 0
            },
            set: { tuning.parameters[key] = $0 }
        )
    }

    private func value(_ key: String) -> Double {
        binding(key).wrappedValue
    }

    private func togglePlay() {
        if isPlayingThis {
            state.voicePreview.stop()
        } else {
            state.playVoicePreview(candidate)
        }
    }

    private func reroll() {
        guard !isRerolling else { return }
        isRerolling = true
        state.voicePreview.stop()
        Task {
            await state.regenerateVoiceCandidate(candidate, tuning: tuning)
            isRerolling = false
        }
    }

    private func save() {
        isSaved = true
        state.saveVoiceCandidate(candidate, name: name, tuning: tuning)
    }
}
