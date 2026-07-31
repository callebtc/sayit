import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceCustomizeSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let profile: VoiceProfileSnapshot
    let model: ModelDescriptor
    let isModelInstalled: Bool

    @State private var tuning: VoiceTuning
    @State private var previewText = ""
    @State private var isPreviewing = false
    @State private var isNamingCopy = false
    @State private var copyName: String

    init(
        profile: VoiceProfileSnapshot,
        model: ModelDescriptor,
        isModelInstalled: Bool
    ) {
        self.profile = profile
        self.model = model
        self.isModelInstalled = isModelInstalled
        var initial = profile.tuning
        if initial.parameters.isEmpty {
            initial.parameters = VoiceTuningSpace.defaults(
                modelType: model.modelType,
                preset: initial.preset
            )
        }
        _tuning = State(initialValue: initial)
        _copyName = State(initialValue: "\(profile.displayName) Copy")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.generousSpacing) {
            header

            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                Text("CHARACTER")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VoiceTuningEditor(
                    model: model,
                    tuning: $tuning,
                    advancedExpanded: true
                )
            }
            .sayItCard()

            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                Text("PREVIEW")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    "Preview text",
                    text: $previewText,
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
                HStack(spacing: DesignTokens.standardSpacing) {
                    Button(action: togglePreview) {
                        Label(
                            isPlayingThis ? "Stop" : "Preview",
                            systemImage: isPlayingThis
                                ? "stop.fill" : "play.fill"
                        )
                        .contentTransition(.symbolEffect(.replace.offUp))
                    }
                    .disabled(
                        isPreviewing || previewTextIsInvalid || !isModelInstalled
                    )
                    if isPreviewing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if !isModelInstalled {
                        Text("Reinstall the model to hear changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sayItCard()

            HStack(spacing: DesignTokens.standardSpacing) {
                Button("Save as New Voice…") {
                    copyName = "\(profile.displayName) Copy"
                    isNamingCopy = true
                }
                .popover(isPresented: $isNamingCopy, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                        TextField("New voice name", text: $copyName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 200)
                            .onSubmit(saveCopy)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                isNamingCopy = false
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            Button("Save", action: saveCopy)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(copyNameIsInvalid)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(DesignTokens.standardSpacing)
                }
                Spacer()
                Button("Apply Changes", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
        }
        .padding(DesignTokens.generousSpacing)
        .frame(width: 520)
        .onAppear {
            if previewText.isEmpty {
                previewText = state.settings.voicePreviewSample
            }
        }
        .onDisappear {
            if isPlayingThis {
                state.voicePreview.stop()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize \(profile.displayName)")
                    .font(.title2.weight(.semibold))
                Text(
                    "Tune how this voice is performed. Preview your changes, then apply them or keep a copy."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var isPlayingThis: Bool {
        state.voicePreview.isPlaying && state.voicePreview.playingID == profile.id
    }

    private var hasChanges: Bool {
        tuning != profile.tuning
    }

    private var previewTextIsInvalid: Bool {
        let count = previewText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...500).contains(count)
    }

    private var copyNameIsInvalid: Bool {
        let count = copyName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
        return !(1...50).contains(count)
    }

    private func togglePreview() {
        if isPlayingThis {
            state.voicePreview.stop()
            return
        }
        guard !isPreviewing else { return }
        isPreviewing = true
        Task {
            await state.previewVoiceProfile(
                profile,
                tuning: tuning,
                text: previewText
            )
            isPreviewing = false
        }
    }

    private func apply() {
        state.updateVoiceTuning(profile, tuning: tuning)
        dismiss()
    }

    private func saveCopy() {
        guard !copyNameIsInvalid else { return }
        state.duplicateVoice(profile, name: copyName, tuning: tuning)
        isNamingCopy = false
    }
}
