import AppKit
import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceCloneWizard: View {
    private enum Step: Int, CaseIterable {
        case prepare
        case record
        case preview

        var title: String {
            switch self {
            case .prepare: "Prepare"
            case .record: "Record"
            case .preview: "Preview & Save"
            }
        }
    }

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let initialModel: ModelDescriptor

    @State private var step = Step.prepare
    @State private var stepDirection = 1
    @State private var selectedModelID: ModelID
    @State private var language: String
    @State private var hasPermissionToClone = false
    @State private var recorder = VoiceRecorder()
    @State private var recordingID: UUID?
    @State private var referenceURL: URL?
    @State private var analysis: VoiceRecordingAnalysis?
    @State private var recordingError: String?
    @State private var tuning: VoiceTuning
    @State private var lastGeneratedTuning: VoiceTuning?
    @State private var name = VoiceCloneWizard.randomName()
    @State private var isSubmitting = false

    init(model: ModelDescriptor) {
        initialModel = model
        _selectedModelID = State(initialValue: model.id)
        _language = State(initialValue: model.defaultLanguage ?? "en-US")
        _tuning = State(
            initialValue: VoiceTuning(
                preset: .natural,
                parameters: VoiceTuningSpace.defaults(
                    modelType: model.modelType,
                    preset: .natural
                )
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                switch step {
                case .prepare:
                    prepareStep.transition(stepTransition)
                case .record:
                    recordStep.transition(stepTransition)
                case .preview:
                    previewStep.transition(stepTransition)
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled(recorder.isRecording || isSubmitting)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            recorder.refreshAccess()
        }
        .onAppear {
            name = uniqueRandomName()
        }
        .onDisappear(perform: cleanUp)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .move(edge: stepDirection > 0 ? .trailing : .leading)),
            removal: .opacity
                .combined(with: .move(edge: stepDirection > 0 ? .leading : .trailing))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clone a Voice")
                        .font(.title2.weight(.semibold))
                    Text("A local reference profile — no training, nothing uploaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            stepIndicator
        }
        .padding(DesignTokens.generousSpacing)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(indicatorFill(for: item))
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .transition(.opacity.combined(with: .scale(scale: 0.5)))
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    item == step ? Color.accentColor : Color.secondary
                                )
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(item.title)
                        .font(.callout.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(
                            item.rawValue <= step.rawValue
                                ? Color.primary
                                : Color.secondary
                        )
                }
                if item != .preview {
                    Capsule()
                        .fill(
                            item.rawValue < step.rawValue
                                ? Color.accentColor.opacity(0.6)
                                : Color.primary.opacity(0.12)
                        )
                        .frame(width: 24, height: 2)
                }
            }
        }
        .animation(DesignTokens.springAnimation, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \(step.rawValue + 1) of 3, \(step.title)"
        )
    }

    private func indicatorFill(for item: Step) -> Color {
        if item.rawValue < step.rawValue { return .accentColor }
        if item == step { return .accentColor.opacity(0.15) }
        return .primary.opacity(0.07)
    }

    private var prepareStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                VStack(alignment: .leading, spacing: 0) {
                    pickerRow(title: "Model") {
                        Picker(selection: $selectedModelID) {
                            ForEach(cloneModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .onChange(of: selectedModelID) {
                            language = selectedModel.defaultLanguage ?? "en-US"
                            tuning = VoiceTuning(
                                preset: .natural,
                                parameters: VoiceTuningSpace.defaults(
                                    modelType: selectedModel.modelType,
                                    preset: .natural
                                )
                            )
                            lastGeneratedTuning = nil
                            name = uniqueRandomName()
                        }
                    }
                    Divider()
                        .padding(.vertical, DesignTokens.compactSpacing)
                    pickerRow(title: "Language") {
                        Picker(selection: $language) {
                            ForEach(selectedModel.languages, id: \.self) {
                                Text($0).tag($0)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .disabled(!selectedModel.capabilities.languageSelection)
                    }
                }
                .sayItCard()

                VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                    guidanceRow(
                        icon: "lock.shield",
                        tint: .accentColor,
                        text: "The recording and generated voice stay on this Mac."
                    )
                    guidanceRow(
                        icon: "waveform.path",
                        tint: .accentColor,
                        text: "Cloning uses your recording as a reference; it does not fine-tune model weights."
                    )
                    if let requirements {
                        guidanceRow(
                            icon: "timer",
                            tint: .accentColor,
                            text: durationGuidance(requirements)
                        )
                    }
                }
                .sayItCard()

                VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                    microphoneStatus
                }
                .sayItCard()

                HStack {
                    Toggle(
                        "I have permission to clone the voice I will record.",
                        isOn: $hasPermissionToClone
                    )
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                .sayItCard()
            }
            .padding(DesignTokens.generousSpacing)
        }
        .scrollIndicators(.never)
    }

    private func pickerRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
                .pickerStyle(.menu)
                .fixedSize()
        }
    }

    private func guidanceRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.standardSpacing) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 6))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                    Text(recordingPrompt.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(recordingPrompt.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(recordingPrompt.accessibilityLabel)
                }
                .sayItCard()

                recordingCard

                microphoneStatusCard
            }
            .padding(DesignTokens.generousSpacing)
        }
        .scrollIndicators(.never)
    }

    private var recordingCard: some View {
        VStack(spacing: DesignTokens.generousSpacing) {
            Text("RECORD")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                Text(durationText)
                    .font(.title.monospacedDigit().weight(.medium))
                    .contentTransition(
                        .numericText(value: recorder.duration.rounded())
                    )
                    .animation(
                        DesignTokens.quickAnimation,
                        value: recorder.duration.rounded()
                    )
                Text(targetDurationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VoiceLevelMeter(level: recorder.level, peak: recorder.peak)

            HStack(spacing: DesignTokens.generousSpacing) {
                ZStack {
                    if showsRecordingPlayback, let referenceURL {
                        Button {
                            play(url: referenceURL)
                        } label: {
                            Image(
                                systemName: state.voicePreview.isPlaying
                                    ? "stop.fill"
                                    : "play.fill"
                            )
                            .contentTransition(.symbolEffect(.replace.offUp))
                        }
                        .buttonStyle(CircularIconButtonStyle(size: 32))
                        .help(
                            state.voicePreview.isPlaying
                                ? "Stop playback"
                                : "Play recording"
                        )
                        .accessibilityLabel(
                            state.voicePreview.isPlaying
                                ? "Stop recording playback"
                                : "Play recording"
                        )
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.6))
                        )
                    }
                }
                .frame(width: 32, height: 32)

                recordButton

                Color.clear
                    .frame(width: 32, height: 32)
            }
            .frame(maxWidth: .infinity)
            .animation(
                DesignTokens.springAnimation,
                value: showsRecordingPlayback
            )

            recordingStatus
                .frame(maxWidth: .infinity)
                .animation(DesignTokens.smoothAnimation, value: statusKey)
        }
        .sayItCard()
    }

    private var durationText: String {
        let duration = recorder.duration
        let minutes = Int(duration) / 60
        let seconds = duration.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private var statusKey: Int {
        if analysis != nil { return 1 }
        if recordingError != nil || recorder.errorMessage != nil { return 2 }
        return recorder.isRecording ? 3 : 0
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if let analysis {
            Label(
                "Ready: \(analysis.duration.formatted(.number.precision(.fractionLength(1)))) seconds of usable audio",
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.green)
            .transition(.opacity)
            .accessibilityLabel("Recording accepted")
        } else if let message = recordingError ?? recorder.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .accessibilityLabel("Recording problem: \(message)")
        } else {
            Text(
                recorder.isRecording
                    ? recordingPrompt.activeInstruction
                    : recordingPrompt.idleInstruction
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.18), lineWidth: 3)
                RoundedRectangle(
                    cornerRadius: recorder.isRecording ? 5 : 23,
                    style: .continuous
                )
                .fill(.red)
                .frame(
                    width: recorder.isRecording ? 20 : 46,
                    height: recorder.isRecording ? 20 : 46
                )
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(DesignTokens.springAnimation, value: recorder.isRecording)
        .disabled(!recorder.isRecording && recorder.access != .granted)
        .opacity(!recorder.isRecording && recorder.access != .granted ? 0.4 : 1)
        .animation(DesignTokens.quickAnimation, value: recorder.access)
        .accessibilityLabel(
            recorder.isRecording ? "Stop recording" : "Start recording"
        )
    }

    @ViewBuilder
    private var microphoneStatusCard: some View {
        if recorder.access != .granted {
            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                microphoneStatus
            }
            .sayItCard()
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var microphoneStatus: some View {
        switch recorder.access {
        case .unknown:
            statusRow(
                icon: "mic.badge.plus",
                text: "Microphone access is needed to record your reference."
            ) {
                Button("Allow Access") {
                    Task { _ = await recorder.requestAccess() }
                }
                .controlSize(.small)
            }
        case .requesting:
            statusRow(
                icon: "ellipsis",
                text: "Waiting for microphone permission…"
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .granted:
            statusRow(icon: recorder.access.symbol, text: "Microphone ready") {}
        case .denied:
            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                statusRow(
                    icon: recorder.access.symbol,
                    text: "Microphone access is denied. Allow Say It in Privacy & Security, then return here."
                ) {}
                Button("Open Microphone Settings", action: openMicrophoneSettings)
                    .controlSize(.small)
            }
        case .restricted:
            statusRow(
                icon: recorder.access.symbol,
                text: "Microphone access is restricted by this Mac. Ask its administrator to allow recording."
            ) {}
        case .noDevice:
            statusRow(
                icon: recorder.access.symbol,
                text: "No input device is available. Connect a microphone or choose one in Sound Settings."
            ) {}
        }
    }

    private func statusRow<Content: View>(
        icon: String,
        text: String,
        @ViewBuilder action: () -> Content
    ) -> some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    .primary.opacity(0.07),
                    in: .rect(cornerRadius: 6)
                )
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }

    private var previewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                samplesCard
                refineCard
                saveCard
            }
            .padding(DesignTokens.generousSpacing)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var samplesCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Text("VALIDATION SAMPLES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let studio = state.voiceStudio,
               studio.id == currentStudioID {
                ForEach(studio.candidates) { candidate in
                    HStack(spacing: DesignTokens.standardSpacing) {
                        VoiceFingerprintView(
                            values: candidate.fingerprint,
                            isActive: isPlaying(candidate)
                        )
                        .frame(width: 140, height: 28)
                        Text(candidate.suggestedName)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            togglePlay(candidate)
                        } label: {
                            Image(
                                systemName: isPlaying(candidate)
                                    ? "stop.fill"
                                    : "play.fill"
                            )
                            .contentTransition(.symbolEffect(.replace.offUp))
                        }
                        .buttonStyle(
                            CircularIconButtonStyle(
                                size: 26,
                                prominent: isPlaying(candidate)
                            )
                        )
                        .accessibilityLabel("Play \(candidate.suggestedName)")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let error = studio.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                VoiceGenerationButton(
                    title: studio.candidates.isEmpty
                        ? "Generate Samples"
                        : "Regenerate Samples",
                    systemImage: "arrow.clockwise",
                    generatingTitle: "Generating samples…",
                    isGenerating: studio.state == .generating,
                    completedCount: studio.completedCount,
                    totalCount: studio.totalCount,
                    isDisabled: recorder.isRecording || isSubmitting
                ) {
                    Task { await generatePreviews(stayOnStep: true) }
                }
            } else {
                HStack(spacing: DesignTokens.compactSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing voice previews…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sayItCard()
        .animation(
            DesignTokens.springAnimation,
            value: state.voiceStudio?.candidates.count
        )
    }

    private var refineCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            Text("REFINE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VoiceTuningEditor(
                model: selectedModel,
                tuning: $tuning
            )
            if lastGeneratedTuning != tuning {
                Label(
                    "Regenerate to hear and save these refinement changes.",
                    systemImage: "arrow.clockwise"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .sayItCard()
        .animation(
            DesignTokens.smoothAnimation,
            value: lastGeneratedTuning != tuning
        )
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            Text("SAVE TO MY VOICES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.compactSpacing) {
                TextField("Voice name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        .primary.opacity(0.05),
                        in: .rect(cornerRadius: DesignTokens.rowCornerRadius)
                    )
                    .accessibilityLabel("Voice name")
                Button {
                    withAnimation(DesignTokens.springAnimation) {
                        name = uniqueRandomName()
                    }
                } label: {
                    Image(systemName: "dice")
                }
                .buttonStyle(CircularIconButtonStyle(size: 26))
                .accessibilityLabel("Suggest a different name")
            }
        }
        .sayItCard()
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            if step != .prepare {
                Button(step == .preview ? "Re-record" : "Back") {
                    if step == .preview {
                        reRecord()
                    } else {
                        changeStep(.prepare)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .prepare:
                Button("Continue") {
                    Task {
                        if await recorder.requestAccess() {
                            changeStep(.record)
                        }
                    }
                }
                .prominentFooterButton()
                .disabled(!hasPermissionToClone || requirements == nil)
            case .record:
                Button("Generate Previews") {
                    Task { await generatePreviews() }
                }
                .prominentFooterButton()
                .disabled(analysis == nil || recorder.isRecording || isSubmitting)
            case .preview:
                Button("Save Voice") {
                    Task { await save() }
                }
                .prominentFooterButton()
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, DesignTokens.generousSpacing)
        .padding(.vertical, DesignTokens.standardSpacing)
        .animation(DesignTokens.smoothAnimation, value: step)
    }

    private var cloneModels: [ModelDescriptor] {
        state.models.filter {
            $0.capabilities.voiceCloneRequirements != nil
                && state.installedModelIDs.contains($0.id)
                && $0.isSelectable
        }
    }

    private var selectedModel: ModelDescriptor {
        cloneModels.first { $0.id == selectedModelID } ?? initialModel
    }

    private var requirements: VoiceCloneRequirements? {
        selectedModel.capabilities.voiceCloneRequirements
    }

    private var passage: String {
        VoiceClonePassage.text(
            language: language,
            targetDuration: requirements?.recommendedMaximumDuration ?? 10
        )
    }

    private var recordingPrompt: VoiceCloneRecordingPrompt {
        VoiceCloneRecordingPrompt(
            passage: passage,
            transcriptRequired: requirements?.transcriptRequired ?? true
        )
    }

    private var targetDurationText: String {
        guard let requirements else { return "" }
        return "Aim for \(Int(requirements.recommendedMinimumDuration))–\(Int(requirements.recommendedMaximumDuration)) seconds"
    }

    private var showsRecordingPlayback: Bool {
        referenceURL != nil && analysis != nil && !recorder.isRecording
    }

    private var currentStudioID: UUID? {
        state.voiceStudio?.modelID == selectedModel.id.rawValue
            ? state.voiceStudio?.id
            : nil
    }

    private var canSave: Bool {
        guard let studio = state.voiceStudio,
              studio.id == currentStudioID,
              studio.state == .ready else {
            return false
        }
        return (1...50).contains(
            name.trimmingCharacters(in: .whitespacesAndNewlines).count
        ) && lastGeneratedTuning == tuning && !isSubmitting
    }

    private func isPlaying(_ candidate: VoiceCandidateSnapshot) -> Bool {
        state.voicePreview.isPlaying
            && state.voicePreview.playingID == candidate.id
    }

    private func togglePlay(_ candidate: VoiceCandidateSnapshot) {
        if isPlaying(candidate) {
            state.voicePreview.stop()
        } else {
            state.playVoicePreview(candidate)
        }
    }

    private func durationGuidance(
        _ requirements: VoiceCloneRequirements
    ) -> String {
        "Record \(Int(requirements.minimumDuration))–\(Int(requirements.maximumDuration)) seconds; \(Int(requirements.recommendedMinimumDuration))–\(Int(requirements.recommendedMaximumDuration)) works best."
    }

    private func changeStep(_ newStep: Step) {
        stepDirection = newStep.rawValue > step.rawValue ? 1 : -1
        if reduceMotion {
            step = newStep
        } else {
            withAnimation(DesignTokens.smoothAnimation) {
                step = newStep
            }
        }
    }

    private func startRecording() {
        do {
            state.voicePreview.stop()
            removeLocalDraft()
            let id = UUID()
            let directories = try AppDirectories.shared(
                appGroupIdentifier: SayItServiceIdentifiers.appGroup
            )
            let directory = directories.voiceDrafts.appending(
                path: id.uuidString,
                directoryHint: .isDirectory
            )
            let rawURL = directory.appending(path: "raw.wav")
            recordingID = id
            analysis = nil
            referenceURL = nil
            recordingError = nil
            try recorder.start(destination: rawURL)
        } catch {
            recordingError = error.localizedDescription
            recorder.refreshAccess()
        }
    }

    private func stopRecording() {
        let rawURL = recorder.stop()
        if let message = recorder.errorMessage {
            analysis = nil
            referenceURL = nil
            recordingError = message
            return
        }
        guard let rawURL,
              let recordingID,
              let requirements else {
            analysis = nil
            referenceURL = nil
            recordingError =
                "No microphone audio was captured. Check the selected input device and record again."
            return
        }
        do {
            let directories = try AppDirectories.shared(
                appGroupIdentifier: SayItServiceIdentifiers.appGroup
            )
            let destination = try draftReferenceURL(
                id: recordingID,
                directories: directories
            )
            let result = try VoiceRecordingProcessor().process(
                source: rawURL,
                destination: destination,
                targetSampleRate: targetSampleRate,
                minimumDuration: requirements.minimumDuration,
                maximumDuration: requirements.maximumDuration
            )
            try? FileManager.default.removeItem(at: rawURL)
            analysis = result
            referenceURL = destination
            recordingError = nil
        } catch {
            analysis = nil
            referenceURL = nil
            recordingError = error.localizedDescription
        }
    }

    private var targetSampleRate: Double {
        VoiceReferenceFormat.sampleRate(
            forModelType: selectedModel.modelType
        )
    }

    private func draftReferenceURL(
        id: UUID,
        directories: AppDirectories
    ) throws -> URL {
        let directory = directories.voiceDrafts.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "reference.wav")
    }

    private func play(url: URL) {
        do {
            try state.voicePreview.play(data: Data(contentsOf: url))
        } catch {
            recordingError = error.localizedDescription
        }
    }

    private func generatePreviews(stayOnStep: Bool = false) async {
        guard let recordingID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let request = VoiceCloneRequest(
            recordingID: recordingID,
            modelID: selectedModel.id.rawValue,
            language: language,
            transcript: recordingPrompt.transcript,
            tuning: tuning
        )
        if await state.startVoiceClone(request) {
            lastGeneratedTuning = tuning
            if !stayOnStep {
                changeStep(.preview)
            }
        }
    }

    private func save() async {
        guard let sessionID = currentStudioID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if await state.saveVoiceClone(
            sessionID: sessionID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            recordingID = nil
            dismiss()
        }
    }

    private func reRecord() {
        state.cancelVoiceStudio()
        state.voicePreview.stop()
        analysis = nil
        referenceURL = nil
        recordingError = nil
        recordingID = nil
        lastGeneratedTuning = nil
        changeStep(.record)
    }

    private func cancel() {
        cleanUp()
        dismiss()
    }

    private func cleanUp() {
        recorder.stop()
        state.cancelVoiceStudio()
        removeLocalDraft()
    }

    private func removeLocalDraft() {
        guard let recordingID,
              let directories = try? AppDirectories.shared(
                  appGroupIdentifier: SayItServiceIdentifiers.appGroup
              ) else {
            return
        }
        let directory = directories.voiceDrafts.appending(
            path: recordingID.uuidString,
            directoryHint: .isDirectory
        )
        try? FileManager.default.removeItem(at: directory)
        self.recordingID = nil
    }

    private func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func uniqueRandomName() -> String {
        let existing = Set(
            state.voiceProfiles
                .filter { $0.modelID == selectedModelID.rawValue }
                .map { $0.displayName.lowercased() }
        )
        for _ in 0..<100 {
            let candidate = Self.randomName()
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
        }
        var suffix = existing.count + 1
        while existing.contains("voice \(suffix)") {
            suffix += 1
        }
        return "Voice \(suffix)"
    }

    private static func randomName() -> String {
        let first = [
            "Calm", "Clear", "Golden", "Mellow", "Silver", "Velvet"
        ].randomElement() ?? "Clear"
        let second = [
            "Cedar", "Finch", "Harbor", "Lark", "Willow", "Wren"
        ].randomElement() ?? "Lark"
        return "\(first) \(second)"
    }
}

private extension View {
    func prominentFooterButton() -> some View {
        buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}
