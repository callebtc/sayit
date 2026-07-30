import Foundation
import OSLog
import SayItCore
import SayItProtocol

@MainActor
public final class SayItBackendService: SayItService {
    private let directories: AppDirectories
    private let catalog: ModelCatalog
    private let modelManager: ModelManager
    private let synthesizer: SynthesisActor
    private let textCleaner = TextCleaner()
    private let playback: any BackendPlaybackControlling
    private let history: HistoryStore
    private let audioArchive: AudioArchive
    private let voiceAudioArchive: AudioArchive
    private let voiceProfiles: VoiceProfileStore
    private let diagnostics: DiagnosticRecorder
    private let huggingFaceTokenStore: KeychainTokenStore
    private let apiTokenStore = APITokenStore()
    private let settingsStore: BackendSettingsStore
    private let jobJournalStore: JobJournalStore
    private let communityModelResolver = CommunityModelResolver()
    private let logger = Logger(
        subsystem: "com.sayit.mac.agent",
        category: "backend"
    )

    private var models: [ModelDescriptor]
    private var installedModelIDs: Set<ModelID> = []
    private var downloadProgress: ModelDownloadProgress?
    private var downloadTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    private var jobsByID: [UUID: SpeechJob] = [:]
    private var jobOrder: [UUID] = []
    private var pendingJobs: [UUID: PendingSpeechJob] = [:]
    private var queuedJobIDs: [UUID] = []
    private var activeJobID: UUID?
    private var activeRequest: SpeechRequest?
    private var statusText = "Starting service"
    private var errorMessage: String?
    private var httpServiceError: String?
    private var revision: UInt64 = 0
    private var modelsRevision: UInt64 = 0
    private var historyRevision: UInt64 = 0
    private var diagnosticsRevision: UInt64 = 0
    private var voicesRevision: UInt64 = 0
    private var voiceStudioTask: Task<Void, Never>?
    private var voiceStudioSnapshot: VoiceStudioSnapshot?
    private var voiceDraftsByID: [UUID: VoiceDraftCandidate] = [:]
    private var lastProgressRevisionDate = Date.distantPast
    private var lastReplayProgressTick: Int?
    private let serviceVersion: String

    public convenience init(
        directories: AppDirectories,
        serviceVersion: String = "0.1.0"
    ) throws {
        try self.init(
            directories: directories,
            serviceVersion: serviceVersion,
            playback: PlaybackController()
        )
    }

    init(
        directories: AppDirectories,
        serviceVersion: String = "0.1.0",
        playback: any BackendPlaybackControlling
    ) throws {
        self.directories = directories
        self.serviceVersion = serviceVersion
        self.playback = playback
        setenv("HF_HUB_CACHE", directories.hubCache.path, 1)

        let catalog = try ModelCatalogLoader().bundledCatalog()
        let settingsStore = BackendSettingsStore(
            directory: directories.applicationSupport
        )
        let jobJournalStore = JobJournalStore(
            directory: directories.applicationSupport
        )
        let history = try HistoryStore(directories: directories)
        let voiceProfiles = VoiceProfileStore(directories: directories)
        let tokenStore = KeychainTokenStore()
        let manager = ModelManager(
            catalog: catalog,
            directories: directories,
            activeModelID: ModelID(settingsStore.value.activeModelID),
            tokenProvider: {
                try await tokenStore.token()
            }
        )

        self.catalog = catalog
        self.settingsStore = settingsStore
        self.jobJournalStore = jobJournalStore
        self.history = history
        self.voiceProfiles = voiceProfiles
        huggingFaceTokenStore = tokenStore
        modelManager = manager
        models = catalog.models
        synthesizer = SynthesisActor { id in
            await manager.installedURL(for: id)
        }
        audioArchive = AudioArchive(directory: directories.historyAudio)
        voiceAudioArchive = AudioArchive(directory: directories.voiceDrafts)
        diagnostics = DiagnosticRecorder(
            fileURL: directories.diagnostics.appending(path: "events.jsonl")
        )

        restoreJobJournal()
        applyPlaybackSettings(settingsStore.value)
        playback.onFailure = { [weak self] message in
            self?.recordFailure(message)
        }
    }

    public func start() async {
        installedModelIDs = await modelManager.installedModelIDs()
        models = await modelManager.models()
        if !installedModelIDs.contains(ModelID(settingsStore.value.activeModelID)),
           let first = models.first(where: {
               installedModelIDs.contains($0.id) && $0.isSelectable
           }) {
            do {
                try await modelManager.select(first.id)
                var settings = settingsStore.value
                settings.activeModelID = first.id.rawValue
                settings.activeVoice = legacyVoice(
                    for: settings.voiceSelections[first.id.rawValue],
                    fallback: first.defaultVoice
                )
                settings.activeLanguage = first.defaultLanguage ?? ""
                try settingsStore.update(settings)
            } catch {
                recordFailure(error.localizedDescription)
            }
        }
        enforceRetention()
        statusText = "Ready to speak"
        self.revision &+= 1
        await diagnostics.record(
            DiagnosticEvent(
                severity: .info,
                category: .lifecycle,
                code: "agent.started"
            )
        )
        diagnosticsRevision &+= 1
        startNextJobIfNeeded()
    }

    public func handle(_ request: ServiceRequest) async -> ServiceResponse {
        guard request.protocolVersion == SayItProtocolVersion.current else {
            return .failure(
                ServiceFailure(
                    code: "protocol.version_mismatch",
                    message: "The client and service use incompatible protocol versions."
                )
            )
        }

        do {
            return try await handle(request.command)
        } catch let failure as ServiceFailure {
            return .failure(failure)
        } catch {
            logger.error("Service command failed: \(error.localizedDescription, privacy: .public)")
            return .failure(
                ServiceFailure(
                    code: "service.command_failed",
                    message: error.localizedDescription
                )
            )
        }
    }

    public func events(after sequence: UInt64) async -> [ServiceEvent] {
        let snapshot = makeSnapshot()
        guard snapshot.revision > sequence else { return [] }
        return [
            ServiceEvent(id: snapshot.revision, snapshot: snapshot)
        ]
    }

    public func authorize(
        token: String,
        for scope: APITokenScope
    ) async throws -> APITokenMetadata {
        try await apiTokenStore.authorize(token, required: scope)
    }

    public func reportServiceError(_ message: String) async {
        errorMessage = message
        statusText = "Needs attention"
        revision &+= 1
        await diagnostics.record(
            DiagnosticEvent(
                severity: .error,
                category: .lifecycle,
                code: "service.transport_failed"
            )
        )
        diagnosticsRevision &+= 1
    }

    public func reportHTTPServiceError(_ message: String) async {
        var settings = settingsStore.value
        settings.httpEnabled = false
        try? settingsStore.update(settings)
        httpServiceError = message
        revision &+= 1
        await diagnostics.record(
            DiagnosticEvent(
                severity: .error,
                category: .lifecycle,
                code: "http.server_failed"
            )
        )
        diagnosticsRevision &+= 1
    }

    public func importUploadedModel(from directory: URL) async throws {
        try await importModelDirectory(directory)
    }

    private func handle(_ command: ServiceCommand) async throws -> ServiceResponse {
        switch command {
        case .snapshot:
            return .snapshot(makeSnapshot())
        case .events(let sequence):
            return .events(await events(after: sequence))
        case .submit(let submission):
            return .job(try submit(submission))
        case .jobs:
            return .jobs(jobOrder.compactMap { jobsByID[$0] })
        case .confirmJob(let id):
            try confirmJob(id)
            return .accepted
        case .cancelJob(let id):
            cancelJob(id)
            return .accepted
        case .play:
            playback.play()
            updateActiveJobState(.playing)
            revision &+= 1
            return .accepted
        case .pause:
            playback.pause()
            updateActiveJobState(.paused)
            revision &+= 1
            return .accepted
        case .clear:
            cancelActiveJob()
            return .accepted
        case .clearError:
            errorMessage = nil
            if activeJobID == nil {
                statusText = "Ready to speak"
            }
            revision &+= 1
            return .accepted
        case .seek(let seconds):
            playback.seek(to: seconds)
            revision &+= 1
            return .accepted
        case .skip(let seconds):
            playback.skip(by: seconds)
            revision &+= 1
            return .accepted
        case .setPlaybackRate(let rate):
            try setPlaybackRate(rate)
            return .accepted
        case .models:
            return .models(models.map(\.serviceSnapshot))
        case .selectModel(let id):
            try await selectModel(ModelID(id))
            return .accepted
        case .installModel(let id):
            try installModel(ModelID(id))
            return .accepted
        case .cancelModelInstall:
            cancelModelInstall()
            return .accepted
        case .removeModel(let id):
            try await removeModel(ModelID(id))
            return .accepted
        case .voices(let modelID):
            let voices = voiceProfiles.snapshots.filter {
                modelID == nil || $0.modelID == modelID
            }
            return .voices(voices)
        case .startVoiceDiscovery(let request):
            return .voiceStudio(try startVoiceDiscovery(request))
        case .cancelVoiceStudio:
            cancelVoiceStudio()
            return .accepted
        case .voicePreview(let id):
            return .file(try voicePreview(id: id))
        case .saveVoiceCandidate(let id, let name):
            _ = try saveVoiceCandidate(id: id, name: name)
            return .accepted
        case .selectVoice(let id):
            try selectVoice(id: id)
            return .accepted
        case .renameVoice(let id, let name):
            _ = try voiceProfiles.rename(id: id, name: name)
            voicesRevision &+= 1
            revision &+= 1
            return .accepted
        case .deleteVoice(let id):
            try deleteVoice(id: id)
            return .accepted
        case .addCommunityModel(
            let repository,
            let revision,
            let accessToken
        ):
            try await addCommunityModel(
                repository: repository,
                revision: revision,
                accessToken: accessToken
            )
            return .accepted
        case .importLocalModel(let bookmark):
            try await importLocalModel(bookmark: bookmark)
            return .accepted
        case .history:
            return .history(history.items.map(\.serviceSnapshot))
        case .exportHistory(let id, let format):
            return .file(try await exportHistory(id: id, format: format))
        case .replayHistory(let id):
            try replayHistory(id)
            return .accepted
        case .regenerateHistory(let id):
            return .job(try regenerateHistory(id))
        case .toggleHistoryPinned(let id):
            try history.togglePinned(id: id)
            historyRevision &+= 1
            return .accepted
        case .deleteHistory(let id):
            try history.remove(id: id)
            historyRevision &+= 1
            return .accepted
        case .clearHistory:
            try history.removeAll()
            historyRevision &+= 1
            return .accepted
        case .diagnostics:
            let events = await diagnostics.events()
            return .diagnostics(events.map(\.serviceSnapshot))
        case .exportDiagnostics:
            return .file(try await exportDiagnostics())
        case .clearDiagnostics:
            try await diagnostics.clear()
            diagnosticsRevision &+= 1
            return .accepted
        case .updateSettings(let settings):
            try await updateSettings(settings)
            return .accepted
        case .tokens:
            return .tokens(try await apiTokenStore.list())
        case .createToken(let name, let scopes):
            return .createdToken(
                try await apiTokenStore.create(name: name, scopes: scopes)
            )
        case .revokeToken(let id):
            try await apiTokenStore.revoke(id)
            return .accepted
        }
    }

    private func startVoiceDiscovery(
        _ request: VoiceDiscoveryRequest
    ) throws -> VoiceStudioSnapshot {
        guard activeJobID == nil, voiceStudioTask == nil else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Finish or stop the current speech before creating voices."
            )
        }
        guard let model = models.first(where: {
            $0.id.rawValue == request.modelID
        }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested speech model was not found."
            )
        }
        guard installedModelIDs.contains(model.id) else {
            throw ServiceFailure(
                code: "model.not_installed",
                message: "Install \(model.displayName) before creating voices."
            )
        }
        guard model.capabilities.supportsVoiceDiscovery else {
            throw ServiceFailure(
                code: "voice.discovery_unsupported",
                message: "\(model.displayName) cannot discover generated voices."
            )
        }
        let sampleText = request.sampleText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !sampleText.isEmpty, sampleText.count <= 500 else {
            throw ServiceFailure(
                code: "voice.invalid_sample_text",
                message: "Use a sample containing 1 to 500 characters."
            )
        }
        guard (1...8).contains(request.candidateCount) else {
            throw ServiceFailure(
                code: "voice.invalid_candidate_count",
                message: "Generate between 1 and 8 voices at a time."
            )
        }

        if let previous = voiceStudioSnapshot {
            voiceProfiles.removeDraft(id: previous.id)
            for candidate in previous.candidates {
                voiceDraftsByID[candidate.id] = nil
            }
        }
        let session = VoiceStudioSnapshot(
            id: UUID(),
            modelID: model.id.rawValue,
            state: .generating,
            completedCount: 0,
            totalCount: request.candidateCount,
            candidates: []
        )
        voiceStudioSnapshot = session
        revision &+= 1
        voiceStudioTask = Task { [weak self] in
            await self?.runVoiceDiscovery(
                sessionID: session.id,
                model: model,
                request: VoiceDiscoveryRequest(
                    modelID: request.modelID,
                    language: request.language,
                    sampleText: sampleText,
                    candidateCount: request.candidateCount,
                    tuning: request.tuning
                )
            )
        }
        return session
    }

    private func runVoiceDiscovery(
        sessionID: UUID,
        model: ModelDescriptor,
        request: VoiceDiscoveryRequest
    ) async {
        do {
            let directory = try voiceProfiles.prepareDraftDirectory(
                id: sessionID
            )
            var candidates: [VoiceCandidateSnapshot] = []
            var existingNames = Set(
                voiceProfiles.records(modelID: model.id.rawValue)
                    .map(\.displayName)
            )
            let tuning = try validatedTuning(
                request.tuning,
                model: model
            )
            for index in 0..<request.candidateCount {
                try Task.checkCancellation()
                let id = UUID()
                let seed = UInt64.random(in: UInt64.min...UInt64.max)
                let generated = try await synthesizer.generateVoiceSample(
                    model: model,
                    text: request.sampleText,
                    language: request.language,
                    tuning: VoiceSynthesisTuning(
                        preset: tuning.preset.rawValue,
                        parameters: tuning.parameters
                    ),
                    seed: seed
                )
                try Task.checkCancellation()
                let audioURL = directory.appending(
                    path: "\(id.uuidString).wav"
                )
                try await voiceAudioArchive.writeWAV(
                    samples: generated.samples,
                    sampleRate: generated.sampleRate,
                    destination: audioURL
                )
                let name = VoiceNameGenerator().name(
                    excluding: existingNames
                )
                existingNames.insert(name)
                let candidate = VoiceCandidateSnapshot(
                    id: id,
                    suggestedName: name,
                    duration: Double(generated.samples.count)
                        / generated.sampleRate,
                    fingerprint: VoiceFingerprint.make(
                        samples: generated.samples
                    )
                )
                candidates.append(candidate)
                voiceDraftsByID[id] = VoiceDraftCandidate(
                    snapshot: candidate,
                    modelID: model.id.rawValue,
                    language: request.language,
                    transcript: request.sampleText,
                    tuning: tuning,
                    generationSeed: seed,
                    audioURL: audioURL
                )
                voiceStudioSnapshot = VoiceStudioSnapshot(
                    id: sessionID,
                    modelID: model.id.rawValue,
                    state: index + 1 == request.candidateCount
                        ? .ready
                        : .generating,
                    completedCount: index + 1,
                    totalCount: request.candidateCount,
                    candidates: candidates
                )
                revision &+= 1
            }
        } catch is CancellationError {
            voiceProfiles.removeDraft(id: sessionID)
            voiceStudioSnapshot = nil
            revision &+= 1
        } catch {
            let current = voiceStudioSnapshot
            voiceStudioSnapshot = VoiceStudioSnapshot(
                id: sessionID,
                modelID: model.id.rawValue,
                state: .failed,
                completedCount: current?.completedCount ?? 0,
                totalCount: request.candidateCount,
                candidates: current?.candidates ?? [],
                errorMessage: error.localizedDescription
            )
            revision &+= 1
        }
        voiceStudioTask = nil
    }

    private func cancelVoiceStudio() {
        voiceStudioTask?.cancel()
        voiceStudioTask = nil
        if let snapshot = voiceStudioSnapshot {
            voiceProfiles.removeDraft(id: snapshot.id)
            for candidate in snapshot.candidates {
                voiceDraftsByID[candidate.id] = nil
            }
        }
        voiceStudioSnapshot = nil
        revision &+= 1
    }

    private func voicePreview(id: UUID) throws -> ExportedFile {
        guard let draft = voiceDraftsByID[id],
              FileManager.default.fileExists(atPath: draft.audioURL.path) else {
            throw ServiceFailure(
                code: "voice.preview_not_found",
                message: "That voice preview is no longer available."
            )
        }
        return ExportedFile(
            filename: "\(id.uuidString).wav",
            contentType: "audio/wav",
            data: try Data(contentsOf: draft.audioURL)
        )
    }

    @discardableResult
    private func saveVoiceCandidate(
        id: UUID,
        name: String
    ) throws -> VoiceProfileSnapshot {
        guard let draft = voiceDraftsByID[id] else {
            throw ServiceFailure(
                code: "voice.preview_not_found",
                message: "That voice preview is no longer available."
            )
        }
        let profile = try voiceProfiles.saveGenerated(draft, name: name)
        try selectVoice(id: profile.id)
        voicesRevision &+= 1
        revision &+= 1
        return profile
    }

    private func selectVoice(id: UUID) throws {
        guard let record = voiceProfiles.record(id: id) else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        var settings = settingsStore.value
        settings.voiceSelections[record.modelID] = .profile(id)
        if settings.activeModelID == record.modelID {
            settings.activeVoice = ""
        }
        try settingsStore.update(settings)
        revision &+= 1
    }

    private func deleteVoice(id: UUID) throws {
        guard let record = voiceProfiles.record(id: id) else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        try voiceProfiles.delete(id: id)
        var settings = settingsStore.value
        if case .profile(let selectedID)? =
            settings.voiceSelections[record.modelID],
           selectedID == id {
            settings.voiceSelections[record.modelID] = .automaticStable
            if settings.activeModelID == record.modelID {
                settings.activeVoice = ""
            }
            try settingsStore.update(settings)
        }
        voicesRevision &+= 1
        revision &+= 1
    }

    private func validatedTuning(
        _ tuning: VoiceTuning,
        model: ModelDescriptor
    ) throws -> VoiceTuning {
        let defaults = tuningDefaults(
            modelType: model.modelType,
            preset: tuning.preset
        )
        let allowed: [String: ClosedRange<Double>] = switch model.modelType
            .lowercased() {
        case "qwen3_tts":
            [
                "temperature": 0.2...1.2,
                "topP": 0.5...1,
                "topK": 0...100,
                "repetitionPenalty": 0.9...1.5
            ]
        case "fish_speech":
            [
                "temperature": 0.2...1.2,
                "topP": 0.5...1,
                "topK": 0...100
            ]
        default:
            [:]
        }
        var values = defaults
        for (key, value) in tuning.parameters {
            guard let range = allowed[key], range.contains(value) else {
                throw ServiceFailure(
                    code: "voice.invalid_tuning",
                    message: "One or more voice refinement settings are invalid."
                )
            }
            values[key] = value
        }
        return VoiceTuning(preset: tuning.preset, parameters: values)
    }

    private func tuningDefaults(
        modelType: String,
        preset: VoiceTuningPreset
    ) -> [String: Double] {
        switch (modelType.lowercased(), preset) {
        case ("qwen3_tts", .faithful):
            [
                "temperature": 0.45,
                "topP": 0.75,
                "topK": 20,
                "repetitionPenalty": 1.3
            ]
        case ("qwen3_tts", .expressive):
            [
                "temperature": 0.85,
                "topP": 0.95,
                "topK": 50,
                "repetitionPenalty": 1.2
            ]
        case ("fish_speech", .faithful):
            ["temperature": 0.55, "topP": 0.65, "topK": 20]
        case ("fish_speech", .expressive):
            ["temperature": 0.9, "topP": 0.9, "topK": 50]
        default:
            [:]
        }
    }

    private func submit(_ submission: SpeechSubmission) throws -> SpeechJob {
        guard voiceStudioTask == nil else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Wait for voice creation to finish before starting speech."
            )
        }
        guard submission.inputFormat != .ssml else {
            throw ServiceFailure(
                code: "speech.unsupported_input_format",
                message: "SSML is reserved for a future version."
            )
        }
        guard !submission.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || submission.representationData?.isEmpty == false else {
            throw ServiceFailure(
                code: "speech.empty_text",
                message: "Submit text containing at least one readable character."
            )
        }

        switch submission.queuePolicy {
        case .enqueue:
            break
        case .interruptCurrent:
            cancelActiveJob(startNext: false)
        case .replaceAll:
            cancelActiveJob(startNext: false)
            cancelQueuedJobs()
        }

        let title = SpeechTitleGenerator().title(from: submission.text)
        let job = SpeechJob(source: submission.source, title: title)
        jobsByID[job.id] = job
        jobOrder.insert(job.id, at: 0)
        pendingJobs[job.id] = PendingSpeechJob(
            submission: submission,
            cleanedText: nil
        )
        if submission.queuePolicy == .interruptCurrent {
            queuedJobIDs.insert(job.id, at: 0)
        } else {
            queuedJobIDs.append(job.id)
        }
        trimJobHistory()
        revision &+= 1
        persistJobJournal()
        startNextJobIfNeeded()
        return job
    }

    private func startNextJobIfNeeded() {
        guard activeJobID == nil, let id = queuedJobIDs.first else { return }
        queuedJobIDs.removeFirst()
        activeJobID = id
        persistJobJournal()
        jobTask = Task { [weak self] in
            await self?.processJob(id)
        }
    }

    private func processJob(_ id: UUID) async {
        guard var pending = pendingJobs[id] else {
            finishJob(id, state: .failed, errorCode: "job.missing")
            return
        }
        updateJob(id, state: .parsing, progress: 0.02)
        statusText = "Cleaning text"

        do {
            let payload = try payload(for: pending.submission)
            let cleaned = try await textCleaner.ingest(payload)
            try Task.checkCancellation()
            if var job = jobsByID[id] {
                job.title = cleaned.title
                jobsByID[id] = job
                revision &+= 1
            }
            pending.cleanedText = cleaned
            pendingJobs[id] = pending
            persistJobJournal()
            if cleaned.requiresLongTextConfirmation,
               !pending.submission.permitsLongText {
                updateJob(id, state: .awaitingConfirmation, progress: 0.05)
                statusText = "Long text needs confirmation"
                jobTask = nil
                return
            }
            try await speak(id: id, cleaned: cleaned, submission: pending.submission)
        } catch is CancellationError {
            finishJob(id, state: .canceled)
        } catch {
            await recordJobFailure(id: id, error: error)
        }
    }

    private func confirmJob(_ id: UUID) throws {
        guard activeJobID == id,
              jobsByID[id]?.state == .awaitingConfirmation,
              let pending = pendingJobs[id],
              let cleaned = pending.cleanedText else {
            throw ServiceFailure(
                code: "job.not_awaiting_confirmation",
                message: "This job is not waiting for confirmation."
            )
        }
        jobTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speak(
                    id: id,
                    cleaned: cleaned,
                    submission: pending.submission
                )
            } catch is CancellationError {
                self.finishJob(id, state: .canceled)
            } catch {
                await self.recordJobFailure(id: id, error: error)
            }
        }
    }

    private func resolveVoice(
        submission: SpeechSubmission,
        settings: BackendSettingsSnapshot,
        model: ModelDescriptor
    ) throws -> ResolvedVoice {
        guard submission.voice == nil || submission.voiceSelection == nil else {
            throw ServiceFailure(
                code: "voice.conflicting_selection",
                message: "Choose either voice or voiceSelection, not both."
            )
        }
        let selection = submission.voiceSelection
            ?? submission.voice.map(VoiceSelection.preset)
            ?? settings.voiceSelections[model.id.rawValue]
            ?? fallbackSelection(settings: settings, model: model)

        switch selection {
        case .automaticStable:
            return ResolvedVoice(
                preset: model.defaultVoice,
                mode: model.capabilities.supportsRandomVoiceSampling
                    ? .automaticStable
                    : .standard,
                reference: nil,
                profileID: nil,
                profileName: nil,
                tuning: nil
            )
        case .preset(let voice):
            if !model.voices.isEmpty, !model.voices.contains(voice) {
                throw ServiceFailure(
                    code: "voice.preset_not_found",
                    message: "The selected preset voice is unavailable for this model."
                )
            }
            return ResolvedVoice(
                preset: voice,
                mode: .standard,
                reference: nil,
                profileID: nil,
                profileName: voice,
                tuning: nil
            )
        case .profile(let id):
            guard let record = voiceProfiles.record(id: id) else {
                throw ServiceFailure(
                    code: "voice.not_found",
                    message: "The saved voice was not found."
                )
            }
            guard record.modelID == model.id.rawValue else {
                throw ServiceFailure(
                    code: "voice.model_mismatch",
                    message: "That voice belongs to a different speech model."
                )
            }
            let referenceURL = try voiceProfiles.referenceURL(for: record)
            return ResolvedVoice(
                preset: nil,
                mode: .savedProfile,
                reference: VoiceReference(
                    audioURL: referenceURL,
                    transcript: record.transcript
                ),
                profileID: record.id,
                profileName: record.displayName,
                tuning: VoiceSynthesisTuning(
                    preset: record.tuning.preset.rawValue,
                    parameters: record.tuning.parameters
                )
            )
        case .randomPerParagraph:
            guard model.capabilities.supportsRandomVoiceSampling else {
                throw ServiceFailure(
                    code: "voice.random_mode_unsupported",
                    message: "\(model.displayName) cannot randomize each paragraph."
                )
            }
            return ResolvedVoice(
                preset: nil,
                mode: .randomPerParagraph,
                reference: nil,
                profileID: nil,
                profileName: nil,
                tuning: nil
            )
        }
    }

    private func fallbackSelection(
        settings: BackendSettingsSnapshot,
        model: ModelDescriptor
    ) -> VoiceSelection {
        if settings.activeModelID == model.id.rawValue,
           let voice = nonEmpty(settings.activeVoice) {
            return .preset(voice)
        }
        if let voice = model.defaultVoice {
            return .preset(voice)
        }
        return .automaticStable
    }

    private func speak(
        id: UUID,
        cleaned: CleanedText,
        submission: SpeechSubmission
    ) async throws {
        let settings = settingsStore.value
        let requestedModelID = ModelID(submission.modelID ?? settings.activeModelID)
        guard let model = models.first(where: { $0.id == requestedModelID }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested speech model was not found."
            )
        }
        guard installedModelIDs.contains(model.id) else {
            throw ServiceFailure(
                code: "model.not_installed",
                message: "Install \(model.displayName) before speaking."
            )
        }

        let pace = closestSpeakingPace(
            to: submission.speakingPace ?? settings.speakingPace
        )
        let resolvedVoice = try resolveVoice(
            submission: submission,
            settings: settings,
            model: model
        )
        let request = SpeechRequest(
            id: id,
            cleanedText: cleaned,
            model: model,
            voice: resolvedVoice.preset,
            language: submission.language ?? nonEmpty(settings.activeLanguage)
                ?? model.defaultLanguage,
            voiceDescription: submission.voiceDescription
                ?? nonEmpty(settings.voiceDescription),
            voiceMode: resolvedVoice.mode,
            voiceReference: resolvedVoice.reference,
            voiceProfileID: resolvedVoice.profileID,
            voiceProfileName: resolvedVoice.profileName,
            voiceTuning: resolvedVoice.tuning,
            speakingPace: model.supportsNativeSpeakingPace ? pace : .natural,
            source: submission.source.triggerSource
        )
        activeRequest = request
        if submission.source != .preview {
            try history.begin(request)
            historyRevision &+= 1
        }

        playback.rate = validatedPlaybackRate(
            submission.playbackRate ?? settings.playbackRate
        )
        playback.prepare(
            requestID: request.id,
            title: cleaned.title,
            estimatedDuration: Double(cleaned.characterCount)
                / 14
                / request.speakingPace.rawValue
        )
        playback.setSpokenText(cleaned.text)
        activeSpokenText = cleaned.text
        spokenTextCursor = cleaned.text.startIndex
        pendingSpokenChunkRange = nil
        spokenAudioCursor = 0
        updateJob(id, state: .preparing, progress: 0.08)
        statusText = "Preparing speech"
        errorMessage = nil

        let stream = await synthesizer.synthesize(request)
        for try await event in stream {
            try Task.checkCancellation()
            try await handleSynthesisEvent(event, request: request)
        }

        while playback.state == .playing
            || playback.state == .paused
            || playback.state == .buffering
            || playback.state == .preparing {
            try Task.checkCancellation()
            if playback.state == .paused {
                updateJob(id, state: .paused, progress: playbackProgress)
            } else {
                updateJob(id, state: .playing, progress: playbackProgress)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        finishJob(id, state: .completed)
    }

    private func handleSynthesisEvent(
        _ event: SynthesisEvent,
        request: SpeechRequest
    ) async throws {
        switch event {
        case .loadingModel:
            statusText = "Loading \(request.model.displayName)"
            updateJob(request.id, state: .preparing, progress: 0.1)
        case .modelLoaded:
            statusText = "Preparing speech"
            updateJob(request.id, state: .synthesizing, progress: 0.15)
        case .creatingArticleVoice:
            statusText = "Creating an article voice"
            updateJob(request.id, state: .synthesizing, progress: 0.12)
        case .chunkStarted(_, let text):
            registerSpokenChunk(text)
        case .audio(let chunk):
            flushPendingSpokenChunk()
            try playback.enqueue(chunk)
            spokenAudioCursor += Double(chunk.samples.count) / chunk.sampleRate
            if playback.shouldStartWhenBuffered {
                playback.play()
                statusText = "Playing"
                updateJob(request.id, state: .playing, progress: playbackProgress)
            } else {
                statusText = "Buffering"
                updateJob(request.id, state: .buffering, progress: 0.2)
            }
        case .metrics(let metrics):
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .info,
                    category: .synthesis,
                    code: "synthesis.chunk_completed",
                    modelID: request.model.id,
                    durationMilliseconds: Int(metrics.generationDuration * 1_000),
                    numericValue: metrics.realTimeFactor
                )
            )
            diagnosticsRevision &+= 1
        case .completed:
            playback.finishBuffering()
            statusText = "Playing"
            updateJob(request.id, state: .playing, progress: playbackProgress)
            if request.source != .preview {
                try await archiveCompletedRequest(request)
            }
            activeRequest = nil
        case .cancelled:
            throw CancellationError()
        }
    }

    private func archiveCompletedRequest(_ request: SpeechRequest) async throws {
        do {
            let archive = try await playback.archive(using: audioArchive)
            do {
                try history.complete(
                    id: request.id,
                    duration: archive.duration,
                    audioRelativePath: archive.relativePath,
                    audioByteCount: archive.byteCount
                )
                historyRevision &+= 1
            } catch {
                await audioArchive.remove(relativePath: archive.relativePath)
                throw error
            }
        } catch {
            try? history.markIncomplete(
                id: request.id,
                state: .failed,
                code: "history.audio_archive_failed"
            )
            historyRevision &+= 1
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .error,
                    category: .history,
                    code: "history.audio_archive_failed",
                    modelID: request.model.id
                )
            )
            diagnosticsRevision &+= 1
        }
    }

    private func cancelJob(_ id: UUID) {
        if activeJobID == id {
            cancelActiveJob()
            return
        }
        queuedJobIDs.removeAll { $0 == id }
        pendingJobs[id] = nil
        finishQueuedJob(id, state: .canceled)
    }

    private func cancelActiveJob(startNext: Bool = true) {
        guard let id = activeJobID else {
            playback.stop()
            statusText = "Ready to speak"
            revision &+= 1
            if startNext {
                startNextJobIfNeeded()
            }
            return
        }
        jobTask?.cancel()
        jobTask = nil
        Task {
            await synthesizer.cancelCurrentRequest()
        }
        playback.stop()
        if let request = activeRequest, request.source != .preview {
            try? history.markIncomplete(id: request.id, state: .canceled)
            historyRevision &+= 1
        }
        activeRequest = nil
        pendingJobs[id] = nil
        activeJobID = nil
        finishQueuedJob(id, state: .canceled)
        statusText = "Ready to speak"
        persistJobJournal()
        if startNext {
            startNextJobIfNeeded()
        }
    }

    private func cancelQueuedJobs() {
        for id in queuedJobIDs {
            pendingJobs[id] = nil
            finishQueuedJob(id, state: .canceled)
        }
        queuedJobIDs.removeAll(keepingCapacity: false)
        persistJobJournal()
    }

    private func finishJob(
        _ id: UUID,
        state: SpeechJobState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        guard activeJobID == id else { return }
        finishQueuedJob(
            id,
            state: state,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
        pendingJobs[id] = nil
        activeJobID = nil
        activeRequest = nil
        jobTask = nil
        statusText = errorMessage == nil ? "Ready to speak" : "Needs attention"
        persistJobJournal()
        startNextJobIfNeeded()
    }

    private func finishQueuedJob(
        _ id: UUID,
        state: SpeechJobState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        guard var job = jobsByID[id] else { return }
        job.state = state
        job.progress = state == .completed ? 1 : job.progress
        job.finishedAt = .now
        job.errorCode = errorCode
        job.errorMessage = errorMessage
        jobsByID[id] = job
        revision &+= 1
        persistJobJournal()
    }

    private func updateJob(
        _ id: UUID,
        state: SpeechJobState,
        progress: Double
    ) {
        guard var job = jobsByID[id], !job.state.isTerminal else { return }
        let previousState = job.state
        if job.startedAt == nil, state != .queued {
            job.startedAt = .now
        }
        job.state = state
        job.progress = min(max(progress, 0), 1)
        jobsByID[id] = job
        let now = Date.now
        if state != previousState
            || now.timeIntervalSince(lastProgressRevisionDate) >= 0.1 {
            revision &+= 1
            lastProgressRevisionDate = now
        }
        if state != previousState {
            persistJobJournal()
        }
    }

    private func updateActiveJobState(_ state: SpeechJobState) {
        guard let id = activeJobID else { return }
        updateJob(id, state: state, progress: playbackProgress)
    }

    private func recordJobFailure(id: UUID, error: Error) async {
        playback.stop()
        if let request = activeRequest, request.source != .preview {
            try? history.markIncomplete(
                id: request.id,
                state: .failed,
                code: "synthesis.failed"
            )
            historyRevision &+= 1
        }
        errorMessage = error.localizedDescription
        await diagnostics.record(
            DiagnosticEvent(
                severity: .error,
                category: .synthesis,
                code: "synthesis.failed",
                modelID: activeRequest?.model.id
            )
        )
        diagnosticsRevision &+= 1
        finishJob(
            id,
            state: .failed,
            errorCode: "synthesis.failed",
            errorMessage: error.localizedDescription
        )
    }

    private var activeSpokenText: String?
    private var spokenTextCursor: String.Index?
    private var pendingSpokenChunkRange: Range<String.Index>?
    private var spokenAudioCursor: TimeInterval = 0

    private func registerSpokenChunk(_ chunkText: String) {
        guard let fullText = activeSpokenText else { return }
        let cursor = spokenTextCursor ?? fullText.startIndex
        var range = fullText.range(of: chunkText, range: cursor..<fullText.endIndex)
        if range == nil {
            range = fullText.range(of: chunkText)
        }
        guard let found = range else { return }
        pendingSpokenChunkRange = found
        spokenTextCursor = found.upperBound
    }

    private func flushPendingSpokenChunk() {
        guard let fullText = activeSpokenText,
              let range = pendingSpokenChunkRange else {
            return
        }
        pendingSpokenChunkRange = nil
        playback.appendSpokenChunk(
            PlaybackTextChunk(
                textStart: fullText.distance(
                    from: fullText.startIndex,
                    to: range.lowerBound
                ),
                textEnd: fullText.distance(
                    from: fullText.startIndex,
                    to: range.upperBound
                ),
                audioStart: spokenAudioCursor
            )
        )
    }

    private func makeSnapshot() -> ServiceSnapshot {
        if activeJobID == nil, playback.state == .playing {
            let tick = Int(playback.elapsed * 10)
            if tick != lastReplayProgressTick {
                lastReplayProgressTick = tick
                revision &+= 1
            }
        } else {
            lastReplayProgressTick = nil
        }
        var activeJob = activeJobID.flatMap { jobsByID[$0] }
        if var job = activeJob, playback.state == .playing {
            job.state = .playing
            job.progress = playbackProgress
            activeJob = job
        }
        return ServiceSnapshot(
            serviceVersion: serviceVersion,
            revision: revision,
            statusText: statusText,
            lastError: errorMessage,
            httpServiceError: httpServiceError,
            activeJob: activeJob,
            queuedJobs: queuedJobIDs.compactMap { jobsByID[$0] },
            playback: PlaybackSnapshot(
                state: playback.state.rawValue,
                elapsed: playback.elapsed,
                generatedDuration: playback.generatedDuration,
                estimatedDuration: playback.estimatedDuration,
                rate: playback.rate,
                currentTitle: playback.currentTitle,
                amplitudes: playback.amplitudes,
                spokenText: playback.spokenText,
                spokenChunks: playback.spokenChunks
            ),
            download: downloadProgress?.serviceSnapshot,
            installedModelIDs: installedModelIDs
                .map(\.rawValue)
                .sorted(),
            settings: settingsStore.value,
            modelsRevision: modelsRevision,
            historyRevision: historyRevision,
            diagnosticsRevision: diagnosticsRevision,
            voicesRevision: voicesRevision,
            voiceStudio: voiceStudioSnapshot
        )
    }

    private func payload(
        for submission: SpeechSubmission
    ) throws -> TextSourcePayload {
        switch submission.inputFormat {
        case .html:
            guard let data = submission.representationData
                ?? submission.text.data(using: .utf8) else {
                throw ServiceFailure(
                    code: "speech.invalid_text",
                    message: "The submitted HTML is not valid UTF-8."
                )
            }
            return TextSourcePayload(
                source: submission.source.triggerSource,
                html: data
            )
        case .richText:
            guard let data = submission.representationData else {
                throw ServiceFailure(
                    code: "speech.invalid_rich_text",
                    message: "The submitted rich text is missing its encoded representation."
                )
            }
            return TextSourcePayload(
                source: submission.source.triggerSource,
                richText: data,
                plainText: submission.text
            )
        case .plainText, .markdown:
            return TextSourcePayload(
                source: submission.source.triggerSource,
                plainText: submission.text
            )
        case .ssml:
            throw ServiceFailure(
                code: "speech.unsupported_input_format",
                message: "SSML is reserved for a future version."
            )
        }
    }

    private func setPlaybackRate(_ rate: Double) throws {
        let validated = validatedPlaybackRate(rate)
        guard validated == rate else {
            throw ServiceFailure(
                code: "playback.invalid_rate",
                message: "Playback rate must be between 0.5 and 2."
            )
        }
        playback.rate = validated
        var settings = settingsStore.value
        settings.playbackRate = validated
        try settingsStore.update(settings)
        revision &+= 1
    }

    private func selectModel(_ id: ModelID) async throws {
        guard let model = models.first(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested model was not found."
            )
        }
        guard installedModelIDs.contains(id) else {
            throw ServiceFailure(
                code: "model.not_installed",
                message: "Install the model before selecting it."
            )
        }
        cancelActiveJob()
        await synthesizer.unloadModel()
        try await modelManager.select(id)
        var settings = settingsStore.value
        settings.activeModelID = id.rawValue
        settings.activeVoice = legacyVoice(
            for: settings.voiceSelections[id.rawValue],
            fallback: model.defaultVoice
        )
        settings.activeLanguage = model.defaultLanguage ?? ""
        try settingsStore.update(settings)
        revision &+= 1
    }

    private func installModel(_ id: ModelID) throws {
        guard downloadTask == nil else {
            throw ServiceFailure(
                code: "model.download_in_progress",
                message: "Another model download is already in progress."
            )
        }
        guard models.contains(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested model was not found."
            )
        }
        errorMessage = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.install(id) { progress in
                    await self.setDownloadProgress(progress)
                }
                await self.finishInstall(id)
            } catch is CancellationError {
                self.finishCanceledInstall()
            } catch {
                self.finishFailedInstall(error)
            }
        }
    }

    private func addCommunityModel(
        repository: String,
        revision: String?,
        accessToken: String?
    ) async throws {
        if let accessToken = nonEmpty(accessToken ?? "") {
            try await huggingFaceTokenStore.save(accessToken)
        }
        let token = try await huggingFaceTokenStore.token()
        let model = try await communityModelResolver.resolve(
            repository: repository,
            revision: revision,
            token: token
        )
        try await modelManager.addCommunityModel(model)
        models = await modelManager.models()
        modelsRevision &+= 1
        self.revision &+= 1
    }

    private func importLocalModel(bookmark: Data) async throws {
        var isStale = false
        let source = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale, source.startAccessingSecurityScopedResource() else {
            throw ServiceFailure(
                code: "model.import_access_denied",
                message: "Say It no longer has access to the selected model folder."
            )
        }
        defer {
            source.stopAccessingSecurityScopedResource()
        }

        try await importModelDirectory(source)
    }

    private func importModelDirectory(_ source: URL) async throws {
        let model = try await communityModelResolver.resolveLocal(
            directory: source
        )
        try await modelManager.importLocalModel(model, from: source)
        try await synthesizer.prepareDependencies(for: model)
        try await modelManager.markDependenciesVerified(model.id)
        models = await modelManager.models()
        installedModelIDs = await modelManager.installedModelIDs()
        modelsRevision &+= 1
        revision &+= 1
    }

    private func cancelModelInstall() {
        guard let current = downloadProgress else { return }
        downloadProgress = ModelDownloadProgress(
            modelID: current.modelID,
            state: .paused,
            completedBytes: current.completedBytes,
            totalBytes: current.totalBytes,
            bytesPerSecond: 0
        )
        downloadTask?.cancel()
        Task {
            await modelManager.cancelInstall(current.modelID)
        }
        statusText = "Download paused"
        revision &+= 1
    }

    private func removeModel(_ id: ModelID) async throws {
        if settingsStore.value.activeModelID == id.rawValue {
            guard let replacement = models.first(where: {
                $0.id != id
                    && installedModelIDs.contains($0.id)
                    && $0.isSelectable
            }) else {
                throw ServiceFailure(
                    code: "model.active_cannot_remove",
                    message: "Install another compatible model before removing the active model."
                )
            }
            await synthesizer.cancelCurrentRequest()
            await synthesizer.unloadModel()
            try await modelManager.select(replacement.id)
            var settings = settingsStore.value
            settings.activeModelID = replacement.id.rawValue
            settings.activeVoice = legacyVoice(
                for: settings.voiceSelections[replacement.id.rawValue],
                fallback: replacement.defaultVoice
            )
            settings.activeLanguage = replacement.defaultLanguage ?? ""
            try settingsStore.update(settings)
        }
        try await modelManager.remove(id)
        models = await modelManager.models()
        installedModelIDs = await modelManager.installedModelIDs()
        modelsRevision &+= 1
        revision &+= 1
    }

    private func setDownloadProgress(_ progress: ModelDownloadProgress) {
        downloadProgress = progress
        statusText = progress.state == .verifying
            ? "Verifying model"
            : "Downloading model"
        revision &+= 1
    }

    private func finishInstall(_ id: ModelID) async {
        if let model = models.first(where: { $0.id == id }) {
            do {
                try await synthesizer.prepareDependencies(for: model)
                try await modelManager.markDependenciesVerified(id)
            } catch {
                finishFailedInstall(error)
                return
            }
        }
        installedModelIDs = await modelManager.installedModelIDs()
        models = await modelManager.models()
        modelsRevision &+= 1
        downloadTask = nil
        downloadProgress = nil
        statusText = "Ready to speak"
        revision &+= 1
    }

    private func finishCanceledInstall() {
        downloadTask = nil
        statusText = "Download paused"
        revision &+= 1
    }

    private func finishFailedInstall(_ error: Error) {
        downloadTask = nil
        if let current = downloadProgress {
            downloadProgress = ModelDownloadProgress(
                modelID: current.modelID,
                state: .failed,
                completedBytes: current.completedBytes,
                totalBytes: current.totalBytes,
                bytesPerSecond: 0
            )
        }
        recordFailure(error.localizedDescription)
    }

    private func replayHistory(_ id: UUID) throws {
        guard let item = history.items.first(where: { $0.id == id }),
              let url = history.audioURL(for: item) else {
            throw ServiceFailure(
                code: "history.audio_unavailable",
                message: "This history item has no completed audio."
            )
        }
        cancelActiveJob(startNext: false)
        try playback.playFile(at: url, title: item.title)
        playback.setSpokenText(item.cleanedText)
        activeSpokenText = item.cleanedText
        spokenTextCursor = item.cleanedText.startIndex
        pendingSpokenChunkRange = nil
        spokenAudioCursor = 0
        errorMessage = nil
        statusText = "Playing"
        revision &+= 1
    }

    private func regenerateHistory(_ id: UUID) throws -> SpeechJob {
        guard let item = history.items.first(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "history.not_found",
                message: "The history item was not found."
            )
        }
        return try submit(
            SpeechSubmission(
                text: item.cleanedText,
                source: .history,
                modelID: item.modelID.rawValue,
                voiceSelection: item.serviceSnapshot.voiceSelection,
                language: item.language,
                queuePolicy: .replaceAll,
                permitsLongText: true
            )
        )
    }

    private func exportHistory(
        id: UUID,
        format: String
    ) async throws -> ExportedFile {
        guard let item = history.items.first(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "history.not_found",
                message: "The history item was not found."
            )
        }
        let baseName = sanitizedFilename(item.title)
        switch format.lowercased() {
        case "txt", "text":
            return ExportedFile(
                filename: "\(baseName).txt",
                contentType: "text/plain; charset=utf-8",
                data: Data(item.cleanedText.utf8)
            )
        case "m4a":
            guard let url = history.audioURL(for: item) else {
                throw ServiceFailure(
                    code: "history.audio_unavailable",
                    message: "This history item has no completed audio."
                )
            }
            return ExportedFile(
                filename: "\(baseName).m4a",
                contentType: "audio/mp4",
                data: try Data(contentsOf: url)
            )
        case "wav":
            guard let source = history.audioURL(for: item) else {
                throw ServiceFailure(
                    code: "history.audio_unavailable",
                    message: "This history item has no completed audio."
                )
            }
            let destination = directories.temporary
                .appending(path: "\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: destination) }
            try await audioArchive.convertToWAV(
                source: source,
                destination: destination
            )
            return ExportedFile(
                filename: "\(baseName).wav",
                contentType: "audio/wav",
                data: try Data(contentsOf: destination)
            )
        default:
            throw ServiceFailure(
                code: "history.unsupported_export_format",
                message: "Use m4a, wav, or text."
            )
        }
    }

    private func exportDiagnostics() async throws -> ExportedFile {
        let events = await diagnostics.events().map(\.serviceSnapshot)
        return ExportedFile(
            filename: "Say It Diagnostics.json",
            contentType: "application/json",
            data: try JSONEncoder.sayIt.encode(events)
        )
    }

    private func updateSettings(
        _ settings: BackendSettingsSnapshot
    ) async throws {
        let previousSettings = settingsStore.value
        let previousModelID = previousSettings.activeModelID
        guard models.contains(where: {
            $0.id.rawValue == settings.activeModelID
        }) else {
            throw ServiceFailure(
                code: "settings.model_not_found",
                message: "The selected model was not found."
            )
        }
        guard SpeakingPace(rawValue: settings.speakingPace) != nil else {
            throw ServiceFailure(
                code: "settings.invalid_speaking_pace",
                message: "Choose one of the supported speaking paces."
            )
        }
        guard (0.5...2).contains(settings.playbackRate) else {
            throw ServiceFailure(
                code: "settings.invalid_playback_rate",
                message: "Playback rate must be between 0.5 and 2."
            )
        }
        try settingsStore.update(settings)
        if settings.httpEnabled != previousSettings.httpEnabled
            || settings.httpPort != previousSettings.httpPort {
            httpServiceError = nil
        }
        applyPlaybackSettings(settings)
        if settings.activeModelID != previousModelID,
           installedModelIDs.contains(ModelID(settings.activeModelID)) {
            await synthesizer.cancelCurrentRequest()
            await synthesizer.unloadModel()
            try await modelManager.select(ModelID(settings.activeModelID))
        }
        enforceRetention()
        revision &+= 1
    }

    private func applyPlaybackSettings(_ settings: BackendSettingsSnapshot) {
        playback.rate = settings.playbackRate
        playback.backwardSkipInterval = settings.rewindInterval
        playback.forwardSkipInterval = settings.forwardInterval
        playback.showTitleInNowPlaying = settings.showNowPlayingTitles
    }

    private func legacyVoice(
        for selection: VoiceSelection?,
        fallback: String?
    ) -> String {
        if case .preset(let voice)? = selection {
            return voice
        }
        return fallback ?? ""
    }

    private func enforceRetention() {
        let settings = settingsStore.value
        let retention = RetentionPeriod(rawValue: settings.retentionPeriod)
            ?? .thirtyDays
        do {
            try history.enforceRetention(
                period: retention,
                quotaBytes: settings.historyQuotaBytes
            )
            historyRevision &+= 1
        } catch {
            logger.error("History retention failed")
        }
    }

    private func recordFailure(_ message: String) {
        errorMessage = message
        statusText = "Needs attention"
        revision &+= 1
    }

    private func trimJobHistory() {
        guard jobOrder.count > 500 else { return }
        let removed = jobOrder.dropFirst(500)
        for id in removed where id != activeJobID {
            jobsByID[id] = nil
            pendingJobs[id] = nil
        }
        jobOrder = Array(jobOrder.prefix(500))
    }

    private func restoreJobJournal() {
        guard let journal = jobJournalStore.load() else { return }
        jobsByID = Dictionary(
            uniqueKeysWithValues: journal.jobs.map { ($0.id, $0) }
        )
        jobOrder = journal.jobs.map(\.id)
        pendingJobs = journal.pendingJobs
        queuedJobIDs = journal.queuedJobIDs.filter {
            pendingJobs[$0] != nil && jobsByID[$0]?.state.isTerminal == false
        }
        if let activeID = journal.activeJobID,
           pendingJobs[activeID] != nil,
           var activeJob = jobsByID[activeID],
           !activeJob.state.isTerminal {
            activeJob.state = .queued
            activeJob.progress = 0
            activeJob.startedAt = nil
            activeJob.finishedAt = nil
            activeJob.errorCode = nil
            activeJob.errorMessage = nil
            jobsByID[activeID] = activeJob
            queuedJobIDs.removeAll { $0 == activeID }
            queuedJobIDs.insert(activeID, at: 0)
        }
        activeJobID = nil
        trimJobHistory()
        persistJobJournal()
    }

    private func persistJobJournal() {
        let journal = JobJournal(
            jobs: jobOrder.compactMap { jobsByID[$0] },
            pendingJobs: pendingJobs,
            queuedJobIDs: queuedJobIDs,
            activeJobID: activeJobID
        )
        do {
            try jobJournalStore.save(journal)
        } catch {
            logger.error("Speech job journal could not be saved")
        }
    }

    private func closestSpeakingPace(to value: Double) -> SpeakingPace {
        SpeakingPace.allCases.min {
            abs($0.rawValue - value) < abs($1.rawValue - value)
        } ?? .natural
    }

    private func validatedPlaybackRate(_ value: Double) -> Double {
        min(max(value, 0.5), 2)
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func sanitizedFilename(_ value: String) -> String {
        value
            .replacing("/", with: "–")
            .replacing(":", with: "–")
    }

    private var playbackProgress: Double {
        guard playback.generatedDuration > 0 else { return 0.2 }
        return min(max(playback.elapsed / playback.generatedDuration, 0.2), 0.99)
    }
}
