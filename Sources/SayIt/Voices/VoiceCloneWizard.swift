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
                parameters: VoiceTuningDefaults.values(
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
            Group {
                switch step {
                case .prepare:
                    prepareStep
                case .record:
                    recordStep
                case .preview:
                    previewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clone a Voice")
                        .font(.title2.weight(.semibold))
                    Text("A local reference profile—no model training or upload.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { item in
                    Label(
                        item.title,
                        systemImage: item.rawValue < step.rawValue
                            ? "checkmark.circle.fill"
                            : "\(item.rawValue + 1).circle"
                    )
                    .foregroundStyle(
                        item.rawValue <= step.rawValue
                            ? Color.primary
                            : Color.secondary
                    )
                    if item != .preview {
                        Divider().frame(width: 28)
                    }
                }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Step \(step.rawValue + 1) of 3, \(step.title)"
            )
        }
        .padding(20)
    }

    private var prepareStep: some View {
        Form {
            Section("Voice model") {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(cloneModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: selectedModelID) {
                    language = selectedModel.defaultLanguage ?? "en-US"
                    tuning = VoiceTuning(
                        preset: .natural,
                        parameters: VoiceTuningDefaults.values(
                            modelType: selectedModel.modelType,
                            preset: .natural
                        )
                    )
                    lastGeneratedTuning = nil
                    name = uniqueRandomName()
                }
                Picker("Language", selection: $language) {
                    ForEach(selectedModel.languages, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .disabled(!selectedModel.capabilities.languageSelection)
            }

            Section("Before you record") {
                Label(
                    "The recording and generated voice stay on this Mac.",
                    systemImage: "lock.shield"
                )
                Label(
                    "Cloning uses the recording as a reference; it does not fine-tune model weights.",
                    systemImage: "waveform.path"
                )
                if let requirements {
                    Label(
                        durationGuidance(requirements),
                        systemImage: "timer"
                    )
                }
            }

            Section("Microphone") {
                microphoneStatus
            }

            Section {
                Toggle(
                    "I have permission to clone the voice I will record.",
                    isOn: $hasPermissionToClone
                )
                .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
    }

    private var recordStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Read this passage naturally")
                    .font(.title3.weight(.semibold))
                Text(passage)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Passage to record")

                microphoneStatus

                VoiceLevelMeter(level: recorder.level, peak: recorder.peak)

                HStack {
                    Label(
                        recorder.duration.formatted(
                            .number.precision(.fractionLength(1))
                        ) + " seconds",
                        systemImage: "timer"
                    )
                    .monospacedDigit()
                    Spacer()
                    Text(targetDurationText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if recorder.isRecording {
                        Button(
                            "Stop Recording",
                            systemImage: "stop.fill",
                            action: stopRecording
                        )
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(
                            analysis == nil ? "Start Recording" : "Record Again",
                            systemImage: "mic.fill",
                            action: startRecording
                        )
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.access != .granted)
                    }
                    if let referenceURL, analysis != nil {
                        Button("Play Recording", systemImage: "play.fill") {
                            play(url: referenceURL)
                        }
                    }
                }

                if let analysis {
                    Label(
                        "Ready: \(analysis.duration.formatted(.number.precision(.fractionLength(1)))) seconds of usable audio",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording accepted")
                }
                if let recordingError {
                    Label(recordingError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Recording problem: \(recordingError)")
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var microphoneStatus: some View {
        switch recorder.access {
        case .unknown:
            Button("Allow Microphone Access", systemImage: "mic.badge.plus") {
                Task { _ = await recorder.requestAccess() }
            }
        case .requesting:
            Label("Waiting for microphone permission", systemImage: "ellipsis")
        case .granted:
            Label("Microphone ready", systemImage: recorder.access.symbol)
                .foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Microphone access is denied. Allow Say It in Privacy & Security, then return here.",
                    systemImage: recorder.access.symbol
                )
                Button("Open Microphone Settings", action: openMicrophoneSettings)
            }
        case .restricted:
            Label(
                "Microphone access is restricted by this Mac. Ask its administrator to allow recording.",
                systemImage: recorder.access.symbol
            )
        case .noDevice:
            Label(
                "No input device is available. Connect a microphone or choose one in Sound Settings.",
                systemImage: recorder.access.symbol
            )
        }
    }

    private var previewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let studio = state.voiceStudio,
                   studio.id == currentStudioID {
                    GroupBox("Validation samples") {
                        VStack(alignment: .leading, spacing: 12) {
                            if studio.state == .generating {
                                ProgressView(
                                    value: Double(studio.completedCount),
                                    total: Double(studio.totalCount)
                                ) {
                                    Text(
                                        "Generating sample \(min(studio.completedCount + 1, studio.totalCount)) of \(studio.totalCount)"
                                    )
                                }
                            }
                            ForEach(studio.candidates) { candidate in
                                HStack {
                                    VoiceFingerprintView(
                                        values: candidate.fingerprint
                                    )
                                    .frame(width: 150, height: 28)
                                    Text(candidate.suggestedName)
                                    Spacer()
                                    Button("Play", systemImage: "play.fill") {
                                        state.playVoicePreview(candidate)
                                    }
                                    .labelStyle(.iconOnly)
                                    .accessibilityLabel(
                                        "Play \(candidate.suggestedName)"
                                    )
                                }
                            }
                            if let error = studio.errorMessage {
                                Label(
                                    error,
                                    systemImage: "exclamationmark.triangle"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView("Preparing voice previews")
                }

                GroupBox("Refine") {
                    VStack(alignment: .leading, spacing: 8) {
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
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox("Save to My Voices") {
                    TextField("Voice name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Voice name")
                }
            }
            .padding(24)
        }
    }

    private var footer: some View {
        HStack {
            if step != .prepare {
                Button(step == .preview ? "Re-record" : "Back") {
                    if step == .preview {
                        reRecord()
                    } else {
                        step = .prepare
                    }
                }
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasPermissionToClone || requirements == nil)
            case .record:
                Button("Generate Previews") {
                    Task { await generatePreviews() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(analysis == nil || recorder.isRecording || isSubmitting)
            case .preview:
                Button("Regenerate") {
                    Task { await generatePreviews(stayOnStep: true) }
                }
                .disabled(isSubmitting || recorder.isRecording)
                Button("Save Voice") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
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

    private var targetDurationText: String {
        guard let requirements else { return "" }
        return "Aim for \(Int(requirements.recommendedMinimumDuration))–\(Int(requirements.recommendedMaximumDuration)) seconds"
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

    private func durationGuidance(
        _ requirements: VoiceCloneRequirements
    ) -> String {
        "Record \(Int(requirements.minimumDuration))–\(Int(requirements.maximumDuration)) seconds; \(Int(requirements.recommendedMinimumDuration))–\(Int(requirements.recommendedMaximumDuration)) works best."
    }

    private func changeStep(_ newStep: Step) {
        if reduceMotion {
            step = newStep
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
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
        guard let rawURL = recorder.stop(),
              let recordingID,
              let requirements else {
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
        selectedModel.modelType.lowercased() == "fish_speech"
            ? 44_100
            : 24_000
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
            transcript: passage,
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
