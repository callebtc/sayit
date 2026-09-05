import Foundation
import OSLog
import SayItCore
import SayItProtocol

@MainActor
public final class SayItBackendService: SayItService {
    private let directories: AppDirectories
    private let catalog: ModelCatalog
    private let modelManager: ModelManager
    private let synthesizer: any BackendSpeechSynthesizing
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
        subsystem: "sh.sayit.mac.agent",
        category: "backend"
    )

    private var models: [ModelDescriptor]
    private var installedModelIDs: Set<ModelID> = []
    private var downloadProgress: ModelDownloadProgress?
    private var downloadTask: Task<Void, Never>?
    private var downloadSequence: UInt64 = 0
    private var cancelingDownloadSequence: UInt64?
    private var modelInstallError: ModelInstallErrorSnapshot?
    private var jobTask: Task<Void, Never>?
    private var modelTransitionTask: Task<Void, Error>?
    private var modelTransitionSequence: UInt64 = 0
    private var jobsByID: [UUID: SpeechJob] = [:]
    private var jobOrder: [UUID] = []
    private var pendingJobs: [UUID: PendingSpeechJob] = [:]
    private var queuedJobIDs: [UUID] = []
    private var activeJobID: UUID?
    private var activeRequest: SpeechRequest?
    private var playbackCompletionJobID: UUID?
    private var playbackCompletionContinuation: CheckedContinuation<
        PlaybackState,
        Never
    >?
    private var synthesisWatchdogTask: Task<Void, Never>?
    private var synthesisWatchdogJobID: UUID?
    private var stalledJobIDs: Set<UUID> = []
    private let synthesisStallTimeout: Duration
    private var statusText = "Starting service"
    private var errorMessage: String?
    private var httpServiceError: String?
    private var httpServiceConfigurationHandler: (
        @MainActor (HTTPServiceConfiguration) -> Void
    )?
    private let eventHub: ServiceEventHub
    private var revision = UInt64.random(in: 1...UInt64(Int64.max)) {
        didSet {
            guard revision != oldValue else { return }
            cachedServiceEvent = nil
            lastPublishedPlaybackState = playback.state
            let playbackContent = currentPlaybackContent
            if lastPlaybackContent != playbackContent {
                lastPlaybackContent = playbackContent
                playbackContentRevision = revision
            }
            if lastAmplitudes != playback.amplitudes {
                lastAmplitudes = playback.amplitudes
                waveformRevision = revision
            }
            let chunks = playback.spokenChunks
            if lastSpokenChunks != chunks {
                // Only the last existing anchor can be finalized; text resets
                // invalidate every anchor, even when the next text is identical.
                var common = min(lastSpokenChunks.count, chunks.count)
                if playbackContentRevision == revision { common = 0 }
                while common > 0 && lastSpokenChunks[common - 1] != chunks[common - 1] {
                    common -= 1
                }
                timingRevisions.replaceSubrange(
                    common...,
                    with: repeatElement(revision, count: chunks.count - common)
                )
                if chunks.isEmpty || common == 0 { timingResetRevision = revision }
                timingRevision = revision
                lastSpokenChunks = chunks
            }
            eventHub.publish(revision)
        }
    }
    private var modelsRevision: UInt64 = 0
    private var historyRevision: UInt64 = 0
    private var diagnosticsRevision: UInt64 = 0
    private var voicesRevision: UInt64 = 0
    private var voiceStudioTask: Task<Void, Never>?
    private var voiceStudioSnapshot: VoiceStudioSnapshot?
    private var voiceDraftsByID: [UUID: VoiceDraftCandidate] = [:]
    private var voiceCloneDraft: VoiceCloneDraft?
    private var lastPlaybackContent: PlaybackContentState?
    private var lastPublishedPlaybackState: PlaybackState?
    private var playbackContentRevision: UInt64 = 0
    private var waveformRevision: UInt64 = 0
    private var timingRevision: UInt64 = 0
    private var timingResetRevision: UInt64 = 0
    private var lastAmplitudes: [Float] = []
    private var lastSpokenChunks: [PlaybackTextChunk] = []
    private var timingRevisions: [UInt64] = []
    private var cachedServiceEvent: ServiceEvent?
    private(set) var eventSnapshotBuildCount = 0
    private var isModelTransitionInProgress = false
    private var isShuttingDown = false
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
        playback: any BackendPlaybackControlling,
        synthesizer: (any BackendSpeechSynthesizing)? = nil,
        catalogOverride: ModelCatalog? = nil,
        modelManagerOverride: ModelManager? = nil,
        eventSleep: ServiceEventHub.Sleep? = nil,
        synthesisStallTimeout: Duration = .seconds(300)
    ) throws {
        self.directories = directories
        self.serviceVersion = serviceVersion
        self.playback = playback
        self.synthesisStallTimeout = synthesisStallTimeout
        if let eventSleep {
            eventHub = ServiceEventHub(sleep: eventSleep)
        } else {
            eventHub = ServiceEventHub()
        }
        setenv("HF_HUB_CACHE", directories.hubCache.path, 1)

        let catalog = if let catalogOverride {
            catalogOverride
        } else {
            try ModelCatalogLoader().bundledCatalog()
        }
        let settingsStore = BackendSettingsStore(
            directory: directories.applicationSupport
        )
        let jobJournalStore = JobJournalStore(
            directory: directories.applicationSupport
        )
        let history = try HistoryStore(directories: directories)
        let voiceProfiles = VoiceProfileStore(directories: directories)
        let tokenStore = KeychainTokenStore()
        let manager = modelManagerOverride ?? ModelManager(
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
        let resolvedSynthesizer: any BackendSpeechSynthesizing
        if let synthesizer {
            resolvedSynthesizer = synthesizer
        } else {
            resolvedSynthesizer = SynthesisActor { id in
                await manager.installedURL(for: id)
            }
        }
        self.synthesizer = resolvedSynthesizer
        audioArchive = AudioArchive(directory: directories.historyAudio)
        voiceAudioArchive = AudioArchive(directory: directories.voiceDrafts)
        diagnostics = DiagnosticRecorder(
            fileURL: directories.diagnostics.appending(path: "events.jsonl")
        )

        restoreJobJournal()
        applyPlaybackSettings(settingsStore.value)
        let initialSettings = settingsStore.value
        Task { [synthesizer = resolvedSynthesizer, textCleaner] in
            await synthesizer.updateConfiguration(
                chunkTarget: initialSettings.chunkCharacterTarget,
                chunkDelay: initialSettings.chunkDelaySeconds,
                paragraphPause: initialSettings.paragraphPauseSeconds,
                idleUnloadDelay: initialSettings.modelUnloadDelaySeconds
            )
            await textCleaner.update(
                options: Self.textCleaningOptions(from: initialSettings)
            )
        }
        playback.onFailure = { [weak self] message in
            self?.recordFailure(message)
        }
        playback.onExternalControl = { [weak self] in
            guard let self else { return }
            self.revision &+= 1
        }
        playback.onStateChange = { [weak self] state in
            self?.playbackStateDidChange(state)
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
                let activeVoice = legacyVoice(
                    for: settings.voiceSelections[first.id.rawValue],
                    fallback: first.defaultVoice
                )
                settings.activeVoice = activeVoice
                settings.activeLanguage = first.inferredLanguage(
                    forPresetVoice: activeVoice
                ) ?? first.defaultLanguage ?? ""
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

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        statusText = "Stopping service"
        revision &+= 1

        let transitionTask = modelTransitionTask
        let installTask = downloadTask
        transitionTask?.cancel()
        installTask?.cancel()
        if let modelID = downloadProgress?.modelID {
            await modelManager.cancelInstall(modelID)
        }

        cancelQueuedJobs()
        await cancelActiveJob(startNext: false)
        synthesisWatchdogTask?.cancel()
        synthesisWatchdogTask = nil
        synthesisWatchdogJobID = nil
        await cancelVoiceStudio()
        await installTask?.value
        _ = await transitionTask?.result
        await synthesizer.unloadModel()
        playback.stop()

        modelTransitionTask = nil
        downloadTask = nil
        statusText = "Service stopped"
        revision &+= 1
    }

    public func handle(_ request: ServiceRequest) async -> ServiceResponse {
        guard !isShuttingDown else {
            return .failure(
                ServiceFailure(
                    code: "service.shutting_down",
                    message: "The background service is shutting down."
                )
            )
        }
        guard request.protocolVersion == SayItProtocolVersion.current else {
            return .failure(
                ServiceFailure(
                    code: "protocol.version_mismatch",
                    message: """
                    The client uses protocol \(request.protocolVersion), but \
                    the service uses protocol \(SayItProtocolVersion.current). \
                    Quit all copies of Say It and reopen the app that matches \
                    your CLI.
                    """
                )
            )
        }

        do {
            return try await handle(request.command)
        } catch is CancellationError {
            return .failure(
                ServiceFailure(
                    code: "service.request_canceled",
                    message: "The request was canceled or superseded."
                )
            )
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
        synchronizePlaybackStateRevision()
        guard revision != sequence else { return [] }
        return [currentServiceEvent()]
    }

    private func waitForEvents(
        after sequence: UInt64,
        playbackInterval: TimeInterval
    ) async throws -> [ServiceEvent] {
        synchronizePlaybackStateRevision()
        if revision != sequence {
            let event = currentServiceEvent()
            return [project(event, after: sequence)]
        }

        let requestedInterval = playbackInterval.isFinite
            ? playbackInterval
            : 1
        let interval = min(max(requestedInterval, 0.1), 5)
        let wasPlaying = playback.state == .playing
        let timeout: Duration = wasPlaying
            ? .milliseconds(Int64((interval * 1_000).rounded()))
            : .seconds(30)
        try await eventHub.wait(
            after: sequence,
            currentRevision: revision,
            timeout: timeout
        )
        try Task.checkCancellation()

        if revision == sequence, wasPlaying {
            revision &+= 1
        }
        guard revision != sequence else { return [] }
        return [project(currentServiceEvent(), after: sequence)]
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

    public func setHTTPServiceConfigurationHandler(
        _ handler: (@MainActor (HTTPServiceConfiguration) -> Void)?
    ) {
        httpServiceConfigurationHandler = handler
        handler?(httpServiceConfiguration)
    }

    public func reportHTTPServiceError(_ message: String) async {
        await waitForPendingModelTransitions()
        var settings = settingsStore.value
        settings.httpEnabled = false
        try? settingsStore.update(settings)
        httpServiceConfigurationHandler?(httpServiceConfiguration)
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
            synchronizePlaybackStateRevision()
            return .snapshot(makeSnapshot())
        case .events(let sequence):
            return .events(await events(after: sequence))
        case .waitForEvents(let sequence, let playbackInterval):
            return .events(
                try await waitForEvents(
                    after: sequence,
                    playbackInterval: playbackInterval
                )
            )
        case .submit(let submission):
            return .job(try await submit(submission))
        case .jobs:
            return .jobs(jobOrder.compactMap { jobsByID[$0] })
        case .confirmJob(let id):
            try confirmJob(id)
            return .accepted
        case .cancelJob(let id):
            await cancelJob(id)
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
            await cancelActiveJob()
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
            try await setPlaybackRate(rate)
            return .accepted
        case .setVolume(let volume):
            try await setVolume(volume)
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
        case .startVoiceClone(let request):
            return .voiceStudio(try startVoiceClone(request))
        case .cancelVoiceStudio:
            await cancelVoiceStudio()
            return .accepted
        case .voicePreview(let id):
            return .file(try voicePreview(id: id))
        case .saveVoiceCandidate(let id, let name, let tuning):
            _ = try await saveVoiceCandidate(id: id, name: name, tuning: tuning)
            return .accepted
        case .regenerateVoiceCandidate(let id, let tuning):
            return .voiceStudio(
                try await regenerateVoiceCandidate(id: id, tuning: tuning)
            )
        case .saveVoiceClone(let id, let name):
            _ = try await saveVoiceClone(sessionID: id, name: name)
            return .accepted
        case .selectVoice(let id):
            try await selectVoice(id: id)
            return .accepted
        case .renameVoice(let id, let name):
            _ = try voiceProfiles.rename(id: id, name: name)
            voicesRevision &+= 1
            revision &+= 1
            return .accepted
        case .reorderVoices(let modelID, let orderedIDs):
            try voiceProfiles.reorder(modelID: modelID, orderedIDs: orderedIDs)
            voicesRevision &+= 1
            revision &+= 1
            return .accepted
        case .updateVoiceTuning(let id, let tuning):
            _ = try updateVoiceTuning(id: id, tuning: tuning)
            voicesRevision &+= 1
            revision &+= 1
            return .accepted
        case .duplicateVoiceProfile(let id, let name, let tuning):
            _ = try duplicateVoiceProfile(id: id, name: name, tuning: tuning)
            voicesRevision &+= 1
            revision &+= 1
            return .accepted
        case .previewVoiceProfile(let id, let tuning, let text):
            return .file(
                try await previewVoiceProfile(id: id, tuning: tuning, text: text)
            )
        case .deleteVoice(let id):
            try await deleteVoice(id: id)
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
            try await replayHistory(id)
            return .accepted
        case .regenerateHistory(let id):
            return .job(try await regenerateHistory(id))
        case .switchPlaybackModel(let id):
            if let job = try await switchPlaybackModel(ModelID(id)) {
                return .job(job)
            }
            return .accepted
        case .toggleHistoryPinned(let id):
            try history.togglePinned(id: id)
            historyRevision &+= 1
            revision &+= 1
            return .accepted
        case .deleteHistory(let id):
            try history.remove(id: id)
            historyRevision &+= 1
            revision &+= 1
            return .accepted
        case .clearHistory:
            try history.removeAll()
            historyRevision &+= 1
            revision &+= 1
            return .accepted
        case .diagnostics:
            let events = await diagnostics.events()
            return .diagnostics(events.map(\.serviceSnapshot))
        case .exportDiagnostics:
            return .file(try await exportDiagnostics())
        case .clearDiagnostics:
            try await diagnostics.clear()
            diagnosticsRevision &+= 1
            revision &+= 1
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

    private var voiceStudioIsBusy: Bool {
        if voiceStudioTask != nil { return true }
        guard activeJobID != nil else { return false }
        return ![PlaybackState.paused, .finished, .failed].contains(playback.state)
    }

    private var modelSwitchIsPending: Bool {
        isModelTransitionInProgress || modelTransitionTask != nil
    }

    private func startVoiceDiscovery(
        _ request: VoiceDiscoveryRequest
    ) throws -> VoiceStudioSnapshot {
        guard !modelSwitchIsPending else {
            throw ServiceFailure(
                code: "model.switch_in_progress",
                message: "Wait for the model switch to finish before creating voices."
            )
        }
        guard !voiceStudioIsBusy else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Pause or stop the current speech before creating voices."
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
        if let candidateTunings = request.candidateTunings,
           candidateTunings.count != request.candidateCount {
            throw ServiceFailure(
                code: "voice.invalid_candidate_count",
                message: "Candidate refinements must match the voice count."
            )
        }

        discardVoiceStudio(removeCloneRecording: true)
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
        var candidateIDs: [UUID] = []
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
            var candidateTunings: [VoiceTuning]?
            if let provided = request.candidateTunings {
                candidateTunings = try provided.map {
                    try validatedTuning($0, model: model)
                }
            }
            for index in 0..<request.candidateCount {
                try Task.checkCancellation()
                let candidateTuning = candidateTunings?[index] ?? tuning
                let id = UUID()
                let seed = UInt64.random(in: UInt64.min...UInt64.max)
                let generated = try await synthesizer.generateVoiceSample(
                    model: model,
                    text: request.sampleText,
                    language: request.language,
                    tuning: VoiceSynthesisTuning(
                        preset: candidateTuning.preset.rawValue,
                        parameters: candidateTuning.parameters
                    ),
                    seed: seed,
                    reference: nil
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
                    ),
                    tuning: candidateTuning
                )
                candidates.append(candidate)
                candidateIDs.append(id)
                voiceDraftsByID[id] = VoiceDraftCandidate(
                    snapshot: candidate,
                    modelID: model.id.rawValue,
                    language: request.language,
                    transcript: request.sampleText,
                    tuning: candidateTuning,
                    generationSeed: seed,
                    audioURL: audioURL
                )
                guard voiceStudioSnapshot?.id == sessionID else {
                    throw CancellationError()
                }
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
            for id in candidateIDs {
                voiceDraftsByID[id] = nil
            }
            if voiceStudioSnapshot?.id == sessionID {
                voiceStudioSnapshot = nil
                revision &+= 1
            }
        } catch {
            if voiceStudioSnapshot?.id == sessionID {
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
        }
        if voiceStudioSnapshot?.id == sessionID {
            voiceStudioTask = nil
        }
    }

    private func startVoiceClone(
        _ request: VoiceCloneRequest
    ) throws -> VoiceStudioSnapshot {
        guard !modelSwitchIsPending else {
            throw ServiceFailure(
                code: "model.switch_in_progress",
                message: "Wait for the model switch to finish before creating voices."
            )
        }
        guard !voiceStudioIsBusy else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Pause or stop the current speech before cloning a voice."
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
                message: "Install \(model.displayName) before cloning a voice."
            )
        }
        guard model.capabilities.voiceCloning,
              let requirements = model.capabilities.voiceCloneRequirements else {
            throw ServiceFailure(
                code: "voice.cloning_unsupported",
                message: "\(model.displayName) does not support voice cloning."
            )
        }
        let transcript = request.transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requirements.transcriptRequired || !transcript.isEmpty else {
            throw ServiceFailure(
                code: "voice.transcript_required",
                message: "Read the displayed passage so its transcript can condition this model."
            )
        }
        guard transcript.count <= 1_000 else {
            throw ServiceFailure(
                code: "voice.invalid_transcript",
                message: "The recording transcript is too long."
            )
        }
        let source = try voiceProfiles.draftURL(id: request.recordingID)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ServiceFailure(
                code: "voice.recording_not_found",
                message: "The recording is no longer available. Record it again."
            )
        }
        let tuning = try validatedTuning(request.tuning, model: model)
        let previousRecordingID = voiceCloneDraft?.recordingID
        discardVoiceStudio(removeCloneRecording: false)
        if let previousRecordingID,
           previousRecordingID != request.recordingID {
            voiceProfiles.removeDraft(id: previousRecordingID)
        }

        let sessionID = UUID()
        let directory = try voiceProfiles.prepareDraftDirectory(id: sessionID)
        let referenceURL = directory.appending(path: "clone-reference.wav")
        let analysis: VoiceRecordingAnalysis
        do {
            analysis = try VoiceRecordingProcessor().validateProcessedReference(
                source: source,
                destination: referenceURL,
                targetSampleRate: VoiceReferenceFormat.sampleRate(
                    forModelType: model.modelType
                ),
                minimumDuration: requirements.minimumDuration,
                maximumDuration: requirements.maximumDuration
            )
        } catch let error as VoiceRecordingError {
            voiceProfiles.removeDraft(id: sessionID)
            throw ServiceFailure(
                code: "voice.invalid_recording",
                message: error.localizedDescription
            )
        }
        let conditioningTranscript = requirements.transcriptRequired
            ? transcript
            : nil
        voiceCloneDraft = VoiceCloneDraft(
            sessionID: sessionID,
            recordingID: request.recordingID,
            modelID: model.id.rawValue,
            language: request.language,
            transcript: conditioningTranscript?.nilIfEmpty,
            duration: analysis.duration,
            tuning: tuning,
            referenceURL: referenceURL
        )
        let session = VoiceStudioSnapshot(
            id: sessionID,
            modelID: model.id.rawValue,
            state: .generating,
            completedCount: 0,
            totalCount: 3,
            candidates: []
        )
        voiceStudioSnapshot = session
        revision &+= 1
        voiceStudioTask = Task { [weak self] in
            await self?.runVoiceClone(
                sessionID: sessionID,
                model: model,
                language: request.language,
                transcript: conditioningTranscript,
                tuning: tuning,
                referenceURL: referenceURL
            )
        }
        return session
    }

    private func runVoiceClone(
        sessionID: UUID,
        model: ModelDescriptor,
        language: String?,
        transcript: String?,
        tuning: VoiceTuning,
        referenceURL: URL
    ) async {
        var candidateIDs: [UUID] = []
        do {
            let previewTexts = clonePreviewTexts(language: language)
            var candidates: [VoiceCandidateSnapshot] = []
            for (index, text) in previewTexts.enumerated() {
                try Task.checkCancellation()
                let id = UUID()
                let seed = UInt64.random(in: UInt64.min...UInt64.max)
                let generated = try await synthesizer.generateVoiceSample(
                    model: model,
                    text: text,
                    language: language,
                    tuning: VoiceSynthesisTuning(
                        preset: tuning.preset.rawValue,
                        parameters: tuning.parameters
                    ),
                    seed: seed,
                    reference: VoiceReference(
                        audioURL: referenceURL,
                        transcript: transcript
                    )
                )
                let audioURL = referenceURL.deletingLastPathComponent()
                    .appending(path: "\(id.uuidString).wav")
                try await voiceAudioArchive.writeWAV(
                    samples: generated.samples,
                    sampleRate: generated.sampleRate,
                    destination: audioURL
                )
                let candidate = VoiceCandidateSnapshot(
                    id: id,
                    suggestedName: "Preview \(index + 1)",
                    duration: Double(generated.samples.count)
                        / generated.sampleRate,
                    fingerprint: VoiceFingerprint.make(
                        samples: generated.samples
                    ),
                    tuning: tuning
                )
                candidates.append(candidate)
                candidateIDs.append(id)
                voiceDraftsByID[id] = VoiceDraftCandidate(
                    snapshot: candidate,
                    modelID: model.id.rawValue,
                    language: language,
                    transcript: text,
                    tuning: tuning,
                    generationSeed: seed,
                    audioURL: audioURL
                )
                guard voiceStudioSnapshot?.id == sessionID else {
                    throw CancellationError()
                }
                voiceStudioSnapshot = VoiceStudioSnapshot(
                    id: sessionID,
                    modelID: model.id.rawValue,
                    state: index + 1 == previewTexts.count
                        ? .ready
                        : .generating,
                    completedCount: index + 1,
                    totalCount: previewTexts.count,
                    candidates: candidates
                )
                revision &+= 1
            }
        } catch is CancellationError {
            voiceProfiles.removeDraft(id: sessionID)
            for id in candidateIDs {
                voiceDraftsByID[id] = nil
            }
            if voiceStudioSnapshot?.id == sessionID {
                voiceStudioSnapshot = nil
                voiceCloneDraft = nil
                revision &+= 1
            }
        } catch {
            if voiceStudioSnapshot?.id == sessionID {
                let current = voiceStudioSnapshot
                voiceStudioSnapshot = VoiceStudioSnapshot(
                    id: sessionID,
                    modelID: model.id.rawValue,
                    state: .failed,
                    completedCount: current?.completedCount ?? 0,
                    totalCount: 3,
                    candidates: current?.candidates ?? [],
                    errorMessage: error.localizedDescription
                )
                revision &+= 1
            }
        }
        if voiceStudioSnapshot?.id == sessionID {
            voiceStudioTask = nil
        }
    }

    private func cancelVoiceStudio() async {
        let task = voiceStudioTask
        task?.cancel()
        voiceStudioTask = nil
        discardVoiceStudio(removeCloneRecording: true)
        revision &+= 1
        await task?.value
    }

    private func discardVoiceStudio(removeCloneRecording: Bool) {
        if let snapshot = voiceStudioSnapshot {
            voiceProfiles.removeDraft(id: snapshot.id)
            for candidate in snapshot.candidates {
                voiceDraftsByID[candidate.id] = nil
            }
        }
        if removeCloneRecording, let draft = voiceCloneDraft {
            voiceProfiles.removeDraft(id: draft.recordingID)
        }
        voiceCloneDraft = nil
        voiceStudioSnapshot = nil
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
        name: String,
        tuning: VoiceTuning
    ) async throws -> VoiceProfileSnapshot {
        await waitForPendingModelTransitions()
        guard let draft = voiceDraftsByID[id] else {
            throw ServiceFailure(
                code: "voice.preview_not_found",
                message: "That voice preview is no longer available."
            )
        }
        guard let model = models.first(where: {
            $0.id.rawValue == draft.modelID
        }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested speech model was not found."
            )
        }
        let validated = try validatedTuning(tuning, model: model)
        let tunedDraft = VoiceDraftCandidate(
            snapshot: draft.snapshot,
            modelID: draft.modelID,
            language: draft.language,
            transcript: draft.transcript,
            tuning: validated,
            generationSeed: draft.generationSeed,
            audioURL: draft.audioURL
        )
        let profile = try voiceProfiles.saveGenerated(tunedDraft, name: name)
        try await selectVoice(id: profile.id)
        voicesRevision &+= 1
        revision &+= 1
        return profile
    }

    private func regenerateVoiceCandidate(
        id: UUID,
        tuning: VoiceTuning
    ) async throws -> VoiceStudioSnapshot {
        await waitForPendingModelTransitions()
        guard voiceStudioTask == nil else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Wait for voice creation to finish before re-rolling."
            )
        }
        guard let session = voiceStudioSnapshot,
              session.candidates.contains(where: { $0.id == id }),
              let draft = voiceDraftsByID[id],
              let model = models.first(where: {
                  $0.id.rawValue == draft.modelID
              }) else {
            throw ServiceFailure(
                code: "voice.preview_not_found",
                message: "That voice preview is no longer available."
            )
        }
        let validated = try validatedTuning(tuning, model: model)
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let generated = try await synthesizer.generateVoiceSample(
            model: model,
            text: draft.transcript,
            language: draft.language,
            tuning: VoiceSynthesisTuning(
                preset: validated.preset.rawValue,
                parameters: validated.parameters
            ),
            seed: seed,
            reference: nil
        )
        try await voiceAudioArchive.writeWAV(
            samples: generated.samples,
            sampleRate: generated.sampleRate,
            destination: draft.audioURL
        )
        let updated = VoiceCandidateSnapshot(
            id: draft.snapshot.id,
            suggestedName: draft.snapshot.suggestedName,
            duration: Double(generated.samples.count) / generated.sampleRate,
            fingerprint: VoiceFingerprint.make(samples: generated.samples),
            tuning: validated
        )
        voiceDraftsByID[id] = VoiceDraftCandidate(
            snapshot: updated,
            modelID: draft.modelID,
            language: draft.language,
            transcript: draft.transcript,
            tuning: validated,
            generationSeed: seed,
            audioURL: draft.audioURL
        )
        let candidates = session.candidates.map {
            $0.id == id ? updated : $0
        }
        let snapshot = VoiceStudioSnapshot(
            id: session.id,
            modelID: session.modelID,
            state: session.state,
            completedCount: session.completedCount,
            totalCount: session.totalCount,
            candidates: candidates
        )
        voiceStudioSnapshot = snapshot
        revision &+= 1
        return snapshot
    }

    private func updateVoiceTuning(
        id: UUID,
        tuning: VoiceTuning
    ) throws -> VoiceProfileSnapshot {
        let model = try modelForVoiceProfile(id: id)
        let validated = try validatedTuning(tuning, model: model)
        return try voiceProfiles.updateTuning(id: id, tuning: validated)
    }

    private func duplicateVoiceProfile(
        id: UUID,
        name: String,
        tuning: VoiceTuning
    ) throws -> VoiceProfileSnapshot {
        let model = try modelForVoiceProfile(id: id)
        let validated = try validatedTuning(tuning, model: model)
        return try voiceProfiles.duplicate(
            id: id,
            name: name,
            tuning: validated
        )
    }

    private func modelForVoiceProfile(
        id: UUID
    ) throws -> ModelDescriptor {
        guard let record = voiceProfiles.record(id: id) else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        guard let model = models.first(where: {
            $0.id.rawValue == record.modelID
        }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested speech model was not found."
            )
        }
        return model
    }

    private func previewVoiceProfile(
        id: UUID,
        tuning: VoiceTuning,
        text: String
    ) async throws -> ExportedFile {
        await waitForPendingModelTransitions()
        guard voiceStudioTask == nil else {
            throw ServiceFailure(
                code: "voice.studio_busy",
                message: "Wait for voice creation to finish before previewing."
            )
        }
        guard let record = voiceProfiles.record(id: id) else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        let model = try modelForVoiceProfile(id: id)
        guard installedModelIDs.contains(model.id) else {
            throw ServiceFailure(
                code: "model.not_installed",
                message: "Install \(model.displayName) before previewing voices."
            )
        }
        let sampleText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sampleText.isEmpty, sampleText.count <= 500 else {
            throw ServiceFailure(
                code: "voice.invalid_sample_text",
                message: "Use a sample containing 1 to 500 characters."
            )
        }
        let validated = try validatedTuning(tuning, model: model)
        let referenceURL = try voiceProfiles.referenceURL(for: record)
        let generated = try await synthesizer.generateVoiceSample(
            model: model,
            text: sampleText,
            language: record.language,
            tuning: VoiceSynthesisTuning(
                preset: validated.preset.rawValue,
                parameters: validated.parameters
            ),
            seed: UInt64.random(in: UInt64.min...UInt64.max),
            reference: VoiceReference(
                audioURL: referenceURL,
                transcript: record.transcript
            )
        )
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audioURL = temporary.appending(path: "preview.wav")
        try await voiceAudioArchive.writeWAV(
            samples: generated.samples,
            sampleRate: generated.sampleRate,
            destination: audioURL
        )
        return ExportedFile(
            filename: "\(id.uuidString).wav",
            contentType: "audio/wav",
            data: try Data(contentsOf: audioURL)
        )
    }

    @discardableResult
    private func saveVoiceClone(
        sessionID: UUID,
        name: String
    ) async throws -> VoiceProfileSnapshot {
        await waitForPendingModelTransitions()
        guard let draft = voiceCloneDraft,
              draft.sessionID == sessionID,
              voiceStudioSnapshot?.id == sessionID,
              voiceStudioSnapshot?.state == .ready else {
            throw ServiceFailure(
                code: "voice.clone_not_ready",
                message: "Finish generating all voice previews before saving."
            )
        }
        let profile = try voiceProfiles.saveRecorded(draft, name: name)
        try await selectVoice(id: profile.id)
        voicesRevision &+= 1
        discardVoiceStudio(removeCloneRecording: true)
        revision &+= 1
        return profile
    }

    private func clonePreviewTexts(language: String?) -> [String] {
        let code = language?.lowercased().split(separator: "-").first
        return switch code {
        case "de":
            [
                "Heute klingt selbst ein vertrauter Satz ein wenig neu.",
                "Eine ruhige Stimme macht lange Texte angenehm und klar.",
                "Kleine Pausen geben jedem Gedanken seinen eigenen Raum."
            ]
        case "fr":
            [
                "Aujourd’hui, une phrase familière semble presque nouvelle.",
                "Une voix calme rend les longs textes clairs et agréables.",
                "De petites pauses donnent à chaque idée son propre espace."
            ]
        case "es":
            [
                "Hoy, incluso una frase conocida suena un poco diferente.",
                "Una voz tranquila vuelve claros y agradables los textos largos.",
                "Las pequeñas pausas dan a cada idea su propio espacio."
            ]
        case "zh":
            [
                "今天，即使熟悉的句子也能听起来焕然一新。",
                "平静的声音让长篇文字清楚而自然。",
                "短暂的停顿为每个想法留出空间。"
            ]
        case "ja":
            [
                "今日は、聞き慣れた文章も少し新鮮に響きます。",
                "落ち着いた声なら、長い文章も明瞭で自然に聞こえます。",
                "短い間が、それぞれの考えに余白を与えます。"
            ]
        case "ko":
            [
                "오늘은 익숙한 문장도 조금 새롭게 들릴 수 있습니다.",
                "차분한 목소리는 긴 글도 또렷하고 자연스럽게 만듭니다.",
                "짧은 쉼은 각각의 생각에 여유를 줍니다."
            ]
        case "ru":
            [
                "Сегодня даже знакомая фраза может прозвучать совсем по-новому.",
                "Спокойный голос делает длинные тексты ясными и естественными.",
                "Короткие паузы дают каждой мысли немного пространства."
            ]
        case "pt":
            [
                "Hoje, até uma frase conhecida pode soar inteiramente nova.",
                "Uma voz calma torna textos longos claros e naturais.",
                "Pequenas pausas dão espaço a cada pensamento."
            ]
        case "it":
            [
                "Oggi anche una frase familiare può sembrare del tutto nuova.",
                "Una voce calma rende i testi lunghi chiari e naturali.",
                "Piccole pause danno a ogni pensiero un po’ di spazio."
            ]
        default:
            [
                "Today, even a familiar sentence can sound entirely new.",
                "A calm voice makes long passages feel clear and effortless.",
                "Small pauses give every thought a little room to breathe."
            ]
        }
    }

    private func selectVoice(id: UUID) async throws {
        await waitForPendingModelTransitions()
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

    private func deleteVoice(id: UUID) async throws {
        await waitForPendingModelTransitions()
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
        try VoiceTuningPolicy().validate(
            tuning,
            modelType: model.modelType
        )
    }

    private func submit(_ submission: SpeechSubmission) async throws -> SpeechJob {
        guard !modelSwitchIsPending else {
            throw ServiceFailure(
                code: "model.switch_in_progress",
                message: "Wait for the model switch to finish before speaking."
            )
        }
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
            await cancelActiveJob(startNext: false)
        case .replaceAll:
            await cancelActiveJob(startNext: false)
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
        guard !isShuttingDown,
              !modelSwitchIsPending,
              activeJobID == nil,
              let id = queuedJobIDs.first else {
            return
        }
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

        if let cleaned = pending.cleanedText {
            do {
                try await speak(
                    id: id,
                    cleaned: cleaned,
                    submission: pending.submission
                )
            } catch is CancellationError {
                if !stalledJobIDs.contains(id) {
                    finishJob(id, state: .canceled)
                }
            } catch {
                await recordJobFailure(id: id, error: error)
            }
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
                activeJobID = nil
                jobTask = nil
                statusText = "Long text needs confirmation"
                persistJobJournal()
                startNextJobIfNeeded()
                return
            }
            try await speak(id: id, cleaned: cleaned, submission: pending.submission)
        } catch is CancellationError {
            if !stalledJobIDs.contains(id) {
                finishJob(id, state: .canceled)
            }
        } catch {
            await recordJobFailure(id: id, error: error)
        }
    }

    private func confirmJob(_ id: UUID) throws {
        guard jobsByID[id]?.state == .awaitingConfirmation,
              pendingJobs[id]?.cleanedText != nil else {
            throw ServiceFailure(
                code: "job.not_awaiting_confirmation",
                message: "This job is not waiting for confirmation."
            )
        }
        updateJob(id, state: .queued, progress: 0.05)
        queuedJobIDs.append(id)
        persistJobJournal()
        startNextJobIfNeeded()
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
        let voiceDescription = model.capabilities.voiceDescription
            ? resolvedVoice.preset
                ?? submission.voiceDescription
                ?? nonEmpty(settings.voiceDescription)
            : submission.voiceDescription
                ?? nonEmpty(settings.voiceDescription)
        let request = SpeechRequest(
            id: id,
            cleanedText: cleaned,
            model: model,
            voice: resolvedVoice.preset,
            language: submission.language
                ?? model.inferredLanguage(forPresetVoice: resolvedVoice.preset)
                ?? nonEmpty(settings.activeLanguage)
                ?? model.defaultLanguage,
            voiceDescription: voiceDescription,
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
        playback.setPlaybackMode(request.model.playbackMode)
        playback.prepare(
            requestID: request.id,
            title: cleaned.title,
            estimatedDuration: Double(cleaned.characterCount)
                / 14
                / request.speakingPace.rawValue,
            modelID: request.model.id.rawValue
        )
        playback.setSpokenText(cleaned.text)
        spokenTextCharacterCount = cleaned.characterCount
        lastRecordedTextEnd = 0
        if submission.source != .preview {
            playbackContext = PlaybackContext(
                text: cleaned.text,
                language: request.language
            )
        }
        pendingSpokenSourceRange = nil
        spokenAudioCursor = 0
        updateJob(id, state: .preparing, progress: 0.08)
        statusText = "Preparing speech"
        errorMessage = nil

        armSynthesisWatchdog(for: id)
        defer { stopSynthesisWatchdog(for: id) }
        let stream = await synthesizer.synthesize(request)
        for try await event in stream {
            try Task.checkCancellation()
            armSynthesisWatchdog(for: id)
            try await handleSynthesisEvent(event, request: request)
        }

        stopSynthesisWatchdog(for: id)
        let terminalState = await waitForPlaybackCompletion(jobID: id)
        try Task.checkCancellation()
        switch terminalState {
        case .finished:
            finishJob(id, state: .completed)
        case .failed:
            throw ServiceFailure(
                code: "playback.failed",
                message: errorMessage ?? "Audio playback failed."
            )
        default:
            throw CancellationError()
        }
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
        case .chunkStarted(_, let chunk):
            registerSpokenChunk(chunk)
        case .audio(let chunk):
            let revisionBeforeAudio = revision
            flushPendingSpokenChunk(speechStartOffset: chunk.speechStartOffset)
            try playback.enqueue(chunk)
            spokenAudioCursor = playback.generatedDuration
            if playback.shouldStartWhenBuffered {
                playback.play()
                statusText = "Playing"
                updateJob(request.id, state: .playing, progress: playbackProgress)
            } else {
                statusText = "Buffering"
                updateJob(request.id, state: .buffering, progress: 0.2)
            }
            if revision == revisionBeforeAudio {
                revision &+= 1
            }
        case .metrics(let metrics):
            finalizeSpokenChunk(audioEnd: playback.generatedDuration + metrics.trailingAudioDuration)
            playback.observeSynthesisMetrics(metrics)
            if playback.shouldStartWhenBuffered {
                playback.play()
                statusText = "Playing"
                updateJob(
                    request.id,
                    state: .playing,
                    progress: playbackProgress
                )
            }
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
            finalizeSpokenChunk(audioEnd: playback.generatedDuration)
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
        let spokenChunks = playback.spokenChunks
        do {
            let archive = try await playback.archive(using: audioArchive)
            do {
                try history.complete(
                    id: request.id,
                    duration: archive.duration,
                    audioRelativePath: archive.relativePath,
                    audioByteCount: archive.byteCount,
                    spokenChunks: spokenChunks
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

    private func cancelJob(_ id: UUID) async {
        if activeJobID == id {
            await cancelActiveJob()
            return
        }
        queuedJobIDs.removeAll { $0 == id }
        pendingJobs[id] = nil
        finishQueuedJob(id, state: .canceled)
        startNextJobIfNeeded()
    }

    private func cancelActiveJob(
        startNext: Bool = true,
        forModelSwitch: Bool = false
    ) async {
        guard let id = activeJobID else {
            if forModelSwitch {
                await playback.stopForModelSwitch()
                await synthesizer.cancelCurrentRequest()
            } else {
                playback.stop()
            }
            statusText = "Ready to speak"
            revision &+= 1
            if startNext, !isShuttingDown, !modelSwitchIsPending {
                startNextJobIfNeeded()
            }
            return
        }
        let task = jobTask
        let request = activeRequest
        task?.cancel()
        resumePlaybackCompletion(for: id, with: .idle)
        stopSynthesisWatchdog(for: id)
        jobTask = nil
        activeRequest = nil
        activeJobID = nil
        pendingJobs[id] = nil
        if forModelSwitch {
            await playback.stopForModelSwitch()
        } else {
            await playback.stopSmoothly()
        }
        if let request, request.source != .preview {
            try? history.markIncomplete(id: request.id, state: .canceled)
            historyRevision &+= 1
        }
        finishQueuedJob(id, state: .canceled)
        statusText = "Ready to speak"
        persistJobJournal()
        await synthesizer.cancelCurrentRequest()
        await task?.value
        if startNext, !isShuttingDown, !modelSwitchIsPending {
            startNextJobIfNeeded()
        }
    }

    private func cancelQueuedJobs() {
        let confirmationJobIDs = pendingJobs.keys.filter {
            jobsByID[$0]?.state == .awaitingConfirmation
        }
        let canceledIDs = Set(queuedJobIDs).union(confirmationJobIDs)
        for id in canceledIDs {
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
        stalledJobIDs.remove(id)
        resumePlaybackCompletion(for: id, with: playback.state)
        stopSynthesisWatchdog(for: id)
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
        let boundedProgress = min(max(progress, 0), 1)
        guard state != previousState || boundedProgress != job.progress else {
            return
        }
        if job.startedAt == nil, state != .queued {
            job.startedAt = .now
        }
        job.state = state
        job.progress = boundedProgress
        jobsByID[id] = job
        revision &+= 1
        if state != previousState {
            persistJobJournal()
        }
    }

    private func updateActiveJobState(_ state: SpeechJobState) {
        guard let id = activeJobID else { return }
        updateJob(id, state: state, progress: playbackProgress)
    }

    private func recordJobFailure(id: UUID, error: Error) async {
        guard activeJobID == id else { return }
        playback.stop()
        let errorCode: String
        if let failure = error as? ServiceFailure {
            errorCode = failure.code
        } else if error is PlaybackError {
            errorCode = "playback.failed"
        } else {
            errorCode = "synthesis.failed"
        }
        if let request = activeRequest, request.source != .preview {
            try? history.markIncomplete(
                id: request.id,
                state: .failed,
                code: errorCode
            )
            historyRevision &+= 1
        }
        errorMessage = error.localizedDescription
        await diagnostics.record(
            DiagnosticEvent(
                severity: .error,
                category: errorCode.hasPrefix("playback.")
                    ? .playback
                    : .synthesis,
                code: errorCode,
                modelID: activeRequest?.model.id
            )
        )
        diagnosticsRevision &+= 1
        finishJob(
            id,
            state: .failed,
            errorCode: errorCode,
            errorMessage: error.localizedDescription
        )
    }

    private var playbackContext: PlaybackContext?
    private var spokenTextCharacterCount = 0
    private var lastRecordedTextEnd = 0
    private var pendingSpokenSourceRange: Range<Int>?
    private var spokenAudioCursor: TimeInterval = 0

    private func registerSpokenChunk(_ chunk: SpeechChunk) {
        let range = chunk.sourceRange
        guard range.lowerBound >= lastRecordedTextEnd,
              range.upperBound <= spokenTextCharacterCount,
              !range.isEmpty else {
            pendingSpokenSourceRange = nil
            return
        }
        pendingSpokenSourceRange = range
    }

    private func finalizeSpokenChunk(audioEnd: TimeInterval) {
        guard let chunk = playback.spokenChunks.last, chunk.audioEnd == nil else { return }
        playback.appendSpokenChunk(PlaybackTextChunk(
            textStart: chunk.textStart,
            textEnd: chunk.textEnd,
            audioStart: chunk.audioStart,
            audioEnd: max(audioEnd, chunk.audioStart)
        ))
        revision &+= 1
    }

    private func flushPendingSpokenChunk(speechStartOffset: TimeInterval) {
        guard let range = pendingSpokenSourceRange else {
            return
        }
        pendingSpokenSourceRange = nil
        finalizeSpokenChunk(audioEnd: spokenAudioCursor)
        playback.appendSpokenChunk(
            PlaybackTextChunk(
                textStart: range.lowerBound,
                textEnd: range.upperBound,
                audioStart: spokenAudioCursor + max(speechStartOffset, 0)
            )
        )
        lastRecordedTextEnd = range.upperBound
    }

    private var currentPlaybackContent: PlaybackContentState {
        PlaybackContentState(
            currentTitle: playback.currentTitle,
            modelID: playback.currentModelID,
            spokenText: playback.spokenText
        )
    }

    private func synchronizePlaybackStateRevision() {
        let currentState = playback.state
        guard let lastPublishedPlaybackState else {
            self.lastPublishedPlaybackState = currentState
            return
        }
        guard lastPublishedPlaybackState != currentState else { return }
        revision &+= 1
    }

    private func playbackStateDidChange(_ state: PlaybackState) {
        switch state {
        case .playing:
            updateActiveJobState(.playing)
        case .paused:
            updateActiveJobState(.paused)
        case .buffering:
            updateActiveJobState(.buffering)
        default:
            break
        }
        revision &+= 1
        if state == .finished || state == .failed {
            if let id = activeJobID {
                resumePlaybackCompletion(for: id, with: state)
            } else {
                startNextJobIfNeeded()
            }
        }
    }

    private func waitForPlaybackCompletion(
        jobID: UUID
    ) async -> PlaybackState {
        if playback.state == .finished
            || playback.state == .failed
            || playback.state == .idle {
            return playback.state
        }
        return await withCheckedContinuation { continuation in
            playbackCompletionJobID = jobID
            playbackCompletionContinuation = continuation
        }
    }

    private func resumePlaybackCompletion(
        for jobID: UUID,
        with state: PlaybackState
    ) {
        guard playbackCompletionJobID == jobID else { return }
        let continuation = playbackCompletionContinuation
        playbackCompletionJobID = nil
        playbackCompletionContinuation = nil
        continuation?.resume(returning: state)
    }

    private func armSynthesisWatchdog(for jobID: UUID) {
        synthesisWatchdogTask?.cancel()
        synthesisWatchdogJobID = jobID
        let timeout = synthesisStallTimeout
        synthesisWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.synthesisDidStall(jobID)
        }
    }

    private func stopSynthesisWatchdog(for jobID: UUID) {
        guard synthesisWatchdogJobID == jobID else { return }
        synthesisWatchdogTask?.cancel()
        synthesisWatchdogTask = nil
        synthesisWatchdogJobID = nil
    }

    private func synthesisDidStall(_ jobID: UUID) async {
        guard activeJobID == jobID else { return }
        synthesisWatchdogTask = nil
        synthesisWatchdogJobID = nil
        stalledJobIDs.insert(jobID)
        jobTask?.cancel()
        playback.stop()
        await synthesizer.cancelCurrentRequest()
        guard activeJobID == jobID else {
            stalledJobIDs.remove(jobID)
            return
        }
        let message = "Speech generation stopped making progress."
        errorMessage = message
        await diagnostics.record(
            DiagnosticEvent(
                severity: .error,
                category: .synthesis,
                code: "synthesis.stalled",
                modelID: activeRequest?.model.id
            )
        )
        diagnosticsRevision &+= 1
        finishJob(
            jobID,
            state: .failed,
            errorCode: "synthesis.stalled",
            errorMessage: message
        )
    }

    private func currentServiceEvent() -> ServiceEvent {
        if let cachedServiceEvent,
           cachedServiceEvent.id == revision {
            return cachedServiceEvent
        }
        eventSnapshotBuildCount &+= 1
        let event = ServiceEvent(id: revision, snapshot: makeSnapshot())
        cachedServiceEvent = event
        return event
    }

    private func project(
        _ event: ServiceEvent,
        after sequence: UInt64
    ) -> ServiceEvent {
        guard sequence > 0, sequence < event.id else { return event }
        let includesText = playbackContentRevision > sequence
        let includesTiming = timingRevision > sequence || includesText
        let timingStart = includesText || timingResetRevision > sequence
            ? 0
            : firstTimingChange(after: sequence)
        return ServiceEvent(
            id: event.id,
            snapshot: event.snapshot.projectingPlayback(
                includesContent: includesText,
                includesWaveform: waveformRevision > sequence || includesText,
                includesTiming: includesTiming,
                timingStartIndex: timingStart
            )
        )
    }

    private func firstTimingChange(after sequence: UInt64) -> Int {
        var lower = 0
        var upper = timingRevisions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timingRevisions[middle] <= sequence { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func makeSnapshot() -> ServiceSnapshot {
        var activeJob = activeJobID.flatMap { jobsByID[$0] }
        if var job = activeJob, playback.state == .playing {
            job.state = .playing
            job.progress = playbackProgress
            activeJob = job
        }
        let playbackContent = currentPlaybackContent
        return ServiceSnapshot(
            serviceVersion: serviceVersion,
            revision: revision,
            statusText: statusText,
            lastError: errorMessage,
            httpServiceError: httpServiceError,
            activeJob: activeJob,
            queuedJobs: queuedJobIDs.compactMap { jobsByID[$0] },
            confirmationJobs: jobOrder.compactMap { id in
                guard let job = jobsByID[id],
                      job.state == .awaitingConfirmation else {
                    return nil
                }
                return job
            },
            queueBlock: queueBlockSnapshot,
            playback: PlaybackSnapshot(
                state: playback.state.rawValue,
                elapsed: playback.elapsed,
                generatedDuration: playback.generatedDuration,
                estimatedDuration: playback.estimatedDuration,
                rate: playback.rate,
                volume: playback.volume,
                currentTitle: playbackContent.currentTitle,
                modelID: playbackContent.modelID,
                amplitudes: playback.amplitudes,
                spokenText: playbackContent.spokenText,
                spokenChunks: playback.spokenChunks,
                includesContent: true
            ),
            download: downloadProgress?.serviceSnapshot,
            modelInstallError: modelInstallError,
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
                html: data,
                plainText: submission.text
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

    private func setPlaybackRate(_ rate: Double) async throws {
        let validated = validatedPlaybackRate(rate)
        guard validated == rate else {
            throw ServiceFailure(
                code: "playback.invalid_rate",
                message: "Playback rate must be between 0.5 and 2."
            )
        }
        await waitForPendingModelTransitions()
        playback.rate = validated
        var settings = settingsStore.value
        settings.playbackRate = validated
        try settingsStore.update(settings)
        revision &+= 1
    }

    private func setVolume(_ volume: Double) async throws {
        let validated = validatedVolume(volume)
        guard validated == volume else {
            throw ServiceFailure(
                code: "playback.invalid_volume",
                message: "Volume must be between 0 and 2."
            )
        }
        playback.volume = validated
        var settings = settingsStore.value
        settings.volume = validated
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
        var settings = settingsStore.value
        settings.activeModelID = id.rawValue
        let activeVoice = legacyVoice(
            for: settings.voiceSelections[id.rawValue],
            fallback: model.defaultVoice
        )
        settings.activeVoice = activeVoice
        settings.activeLanguage = model.inferredLanguage(
            forPresetVoice: activeVoice
        ) ?? model.defaultLanguage ?? ""
        try await enqueueModelTransition(to: id, settings: settings)
    }

    private func enqueueModelTransition(
        to id: ModelID,
        settings: BackendSettingsSnapshot
    ) async throws {
        modelTransitionSequence &+= 1
        let sequence = modelTransitionSequence
        let predecessor = modelTransitionTask
        predecessor?.cancel()
        let task = Task { @MainActor [weak self, predecessor] in
            if let predecessor {
                _ = await predecessor.result
            }
            try Task.checkCancellation()
            guard let self else {
                throw CancellationError()
            }
            try await self.performModelTransition(to: id, settings: settings)
        }
        modelTransitionTask = task

        do {
            try await task.value
        } catch {
            if sequence == modelTransitionSequence {
                modelTransitionTask = nil
            }
            throw error
        }
        if sequence == modelTransitionSequence {
            modelTransitionTask = nil
        }
    }

    private func performModelTransition(
        to id: ModelID,
        settings requestedSettings: BackendSettingsSnapshot
    ) async throws {
        guard models.contains(where: { $0.id == id }) else {
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

        var settings = requestedSettings
        settings.activeModelID = id.rawValue
        let previousSettings = settingsStore.value
        let previousID = ModelID(previousSettings.activeModelID)
        guard previousID != id else {
            try settingsStore.update(settings)
            revision &+= 1
            return
        }

        isModelTransitionInProgress = true
        statusText = "Switching model"
        revision &+= 1
        let started = ContinuousClock.now
        await diagnostics.record(
            DiagnosticEvent(
                severity: .info,
                category: .model,
                code: "model.switch_started",
                modelID: id
            )
        )
        diagnosticsRevision &+= 1

        do {
            await cancelVoiceStudio()
            await cancelActiveJob(
                startNext: false,
                forModelSwitch: true
            )
            cancelQueuedJobs()
            await synthesizer.unloadModel()
            try Task.checkCancellation()
            do {
                try await modelManager.select(id)
                try Task.checkCancellation()
                try settingsStore.update(settings)
            } catch {
                let transitionError = error
                do {
                    try await modelManager.select(previousID)
                } catch {
                    await diagnostics.record(
                        DiagnosticEvent(
                            severity: .error,
                            category: .model,
                            code: "model.switch_rollback_failed",
                            modelID: id
                        )
                    )
                    diagnosticsRevision &+= 1
                    throw ServiceFailure(
                        code: "model.switch_rollback_failed",
                        message: "The previous model could not be restored after the switch failed."
                    )
                }
                throw transitionError
            }

            isModelTransitionInProgress = false
            statusText = "Ready to speak"
            errorMessage = nil
            revision &+= 1
            let duration = started.duration(to: .now)
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .info,
                    category: .model,
                    code: "model.switch_completed",
                    modelID: id,
                    durationMilliseconds: Int(
                        duration.components.seconds * 1_000
                            + duration.components.attoseconds / 1_000_000_000_000_000
                    )
                )
            )
            diagnosticsRevision &+= 1
        } catch is CancellationError {
            isModelTransitionInProgress = false
            if !isShuttingDown {
                statusText = "Switching model"
                revision &+= 1
            }
            let duration = started.duration(to: .now)
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .info,
                    category: .model,
                    code: "model.switch_canceled",
                    modelID: id,
                    durationMilliseconds: Int(
                        duration.components.seconds * 1_000
                            + duration.components.attoseconds / 1_000_000_000_000_000
                    )
                )
            )
            diagnosticsRevision &+= 1
            throw CancellationError()
        } catch {
            isModelTransitionInProgress = false
            statusText = "Model switch failed"
            errorMessage = error.localizedDescription
            revision &+= 1
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .error,
                    category: .model,
                    code: "model.switch_failed",
                    modelID: id
                )
            )
            diagnosticsRevision &+= 1
            throw error
        }
    }

    private func installModel(_ id: ModelID) throws {
        guard downloadTask == nil else {
            throw ServiceFailure(
                code: "model.download_in_progress",
                message: "Another model download is already in progress."
            )
        }
        guard let model = models.first(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "model.not_found",
                message: "The requested model was not found."
            )
        }
        errorMessage = nil
        modelInstallError = nil
        downloadSequence &+= 1
        let sequence = downloadSequence
        cancelingDownloadSequence = nil
        downloadProgress = ModelDownloadProgress(
            modelID: id,
            state: .queued,
            completedBytes: 0,
            totalBytes: model.downloadByteCount,
            bytesPerSecond: 0
        )
        statusText = "Preparing model download"
        revision &+= 1
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.install(id) { progress in
                    await self.setDownloadProgress(
                        progress,
                        sequence: sequence
                    )
                }
                try Task.checkCancellation()
                try await self.finishInstall(id, sequence: sequence)
            } catch is CancellationError {
                self.finishCanceledInstall(id, sequence: sequence)
            } catch {
                self.finishFailedInstall(
                    error,
                    modelID: id,
                    sequence: sequence
                )
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
        guard downloadTask != nil else {
            downloadProgress = nil
            modelInstallError = nil
            statusText = "Ready to speak"
            revision &+= 1
            return
        }
        guard cancelingDownloadSequence != downloadSequence else { return }
        cancelingDownloadSequence = downloadSequence
        downloadProgress = ModelDownloadProgress(
            modelID: current.modelID,
            state: .canceling,
            completedBytes: current.completedBytes,
            totalBytes: current.totalBytes,
            bytesPerSecond: 0
        )
        downloadTask?.cancel()
        Task {
            await modelManager.cancelInstall(current.modelID)
        }
        statusText = "Canceling model download"
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
            var settings = settingsStore.value
            settings.activeModelID = replacement.id.rawValue
            let activeVoice = legacyVoice(
                for: settings.voiceSelections[replacement.id.rawValue],
                fallback: replacement.defaultVoice
            )
            settings.activeVoice = activeVoice
            settings.activeLanguage = replacement.inferredLanguage(
                forPresetVoice: activeVoice
            ) ?? replacement.defaultLanguage ?? ""
            try await enqueueModelTransition(
                to: replacement.id,
                settings: settings
            )
        }
        try await modelManager.remove(id)
        models = await modelManager.models()
        installedModelIDs = await modelManager.installedModelIDs()
        modelsRevision &+= 1
        revision &+= 1
    }

    private func setDownloadProgress(
        _ progress: ModelDownloadProgress,
        sequence: UInt64
    ) {
        guard sequence == downloadSequence,
              cancelingDownloadSequence != sequence,
              downloadTask != nil else {
            return
        }
        let visibleProgress = if progress.state == .installed {
            ModelDownloadProgress(
                modelID: progress.modelID,
                state: .verifying,
                completedBytes: progress.completedBytes,
                totalBytes: progress.totalBytes,
                bytesPerSecond: 0
            )
        } else {
            progress
        }
        downloadProgress = visibleProgress
        statusText = visibleProgress.state == .verifying
            ? "Finishing model setup"
            : "Downloading model"
        revision &+= 1
    }

    private func finishInstall(
        _ id: ModelID,
        sequence: UInt64
    ) async throws {
        guard sequence == downloadSequence else { return }
        if let current = downloadProgress {
            downloadProgress = ModelDownloadProgress(
                modelID: id,
                state: .verifying,
                completedBytes: current.completedBytes,
                totalBytes: current.totalBytes,
                bytesPerSecond: 0
            )
            statusText = "Finishing model setup"
            revision &+= 1
        }
        if let model = models.first(where: { $0.id == id }) {
            try Task.checkCancellation()
            try await synthesizer.prepareDependencies(for: model)
            try Task.checkCancellation()
            try await modelManager.markDependenciesVerified(id)
        }
        try Task.checkCancellation()
        guard sequence == downloadSequence else { return }
        installedModelIDs = await modelManager.installedModelIDs()
        models = await modelManager.models()
        modelsRevision &+= 1
        downloadTask = nil
        downloadProgress = nil
        cancelingDownloadSequence = nil
        modelInstallError = nil
        statusText = "Ready to speak"
        revision &+= 1
    }

    private func finishCanceledInstall(
        _ id: ModelID,
        sequence: UInt64
    ) {
        guard sequence == downloadSequence else { return }
        let current = downloadProgress
        downloadTask = nil
        cancelingDownloadSequence = nil
        downloadProgress = ModelDownloadProgress(
            modelID: id,
            state: .paused,
            completedBytes: current?.completedBytes ?? 0,
            totalBytes: current?.totalBytes ?? 0,
            bytesPerSecond: 0
        )
        statusText = "Download paused"
        revision &+= 1
    }

    private func finishFailedInstall(
        _ error: Error,
        modelID: ModelID,
        sequence: UInt64
    ) {
        guard sequence == downloadSequence else { return }
        let current = downloadProgress
        downloadTask = nil
        cancelingDownloadSequence = nil
        downloadProgress = ModelDownloadProgress(
            modelID: modelID,
            state: .failed,
            completedBytes: current?.completedBytes ?? 0,
            totalBytes: current?.totalBytes ?? 0,
            bytesPerSecond: 0
        )
        modelInstallError = ModelInstallErrorSnapshot(
            modelID: modelID.rawValue,
            message: error.localizedDescription
        )
        statusText = "Model download failed"
        revision &+= 1
        Task { [weak self] in
            guard let self else { return }
            await self.diagnostics.record(
                DiagnosticEvent(
                    severity: .error,
                    category: .download,
                    code: "model.install_failed"
                )
            )
            self.diagnosticsRevision &+= 1
            self.revision &+= 1
        }
    }

    private func replayHistory(_ id: UUID) async throws {
        guard let item = history.items.first(where: { $0.id == id }),
              let url = history.audioURL(for: item) else {
            throw ServiceFailure(
                code: "history.audio_unavailable",
                message: "This history item has no completed audio."
            )
        }
        await cancelActiveJob(startNext: false)
        cancelQueuedJobs()
        try playback.playFile(
            at: url,
            title: item.title,
            modelID: item.modelID.rawValue
        )
        playback.setSpokenText(item.cleanedText)
        for chunk in try history.playbackTiming(id: id) {
            playback.appendSpokenChunk(chunk)
        }
        spokenTextCharacterCount = item.cleanedText.count
        lastRecordedTextEnd = 0
        playbackContext = PlaybackContext(
            text: item.cleanedText,
            language: item.language
        )
        pendingSpokenSourceRange = nil
        spokenAudioCursor = 0
        errorMessage = nil
        statusText = "Playing"
        revision &+= 1
    }

    private func regenerateHistory(_ id: UUID) async throws -> SpeechJob {
        guard let item = history.items.first(where: { $0.id == id }) else {
            throw ServiceFailure(
                code: "history.not_found",
                message: "The history item was not found."
            )
        }
        return try await submit(
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

    private func switchPlaybackModel(_ id: ModelID) async throws -> SpeechJob? {
        guard models.contains(where: { $0.id == id }) else {
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
        let context = playback.state == .idle ? nil : playbackContext
        if id != ModelID(settingsStore.value.activeModelID) {
            try await selectModel(id)
        }
        guard let context else { return nil }
        return try await submit(
            SpeechSubmission(
                text: context.text,
                source: .history,
                modelID: id.rawValue,
                language: context.language,
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
        _ requestedSettings: BackendSettingsSnapshot
    ) async throws {
        let modelIDAtReceipt = settingsStore.value.activeModelID
        var settings = requestedSettings
        if settings.activeModelID == modelIDAtReceipt {
            await waitForPendingModelTransitions()
            let currentSettings = settingsStore.value
            if currentSettings.activeModelID != modelIDAtReceipt {
                // This was a general settings write based on a snapshot taken
                // before a model switch completed. Keep the authoritative
                // model-specific values instead of silently switching back.
                settings.activeModelID = currentSettings.activeModelID
                settings.activeVoice = currentSettings.activeVoice
                settings.activeLanguage = currentSettings.activeLanguage
            }
        }

        let previousSettings = settingsStore.value
        let previousModelID = previousSettings.activeModelID
        let requestedModelID = ModelID(settings.activeModelID)
        guard models.contains(where: {
            $0.id == requestedModelID
        }) else {
            throw ServiceFailure(
                code: "settings.model_not_found",
                message: "The selected model was not found."
            )
        }
        if settings.activeModelID != previousModelID,
           !installedModelIDs.contains(requestedModelID) {
            throw ServiceFailure(
                code: "model.not_installed",
                message: "Install the model before selecting it."
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
        guard (0...2).contains(settings.volume) else {
            throw ServiceFailure(
                code: "settings.invalid_volume",
                message: "Volume must be between 0 and 2."
            )
        }
        guard (1...5_000).contains(settings.chunkCharacterTarget) else {
            throw ServiceFailure(
                code: "settings.invalid_chunk_size",
                message: "Text block size must be between 1 and 5,000 characters."
            )
        }
        guard (0...10).contains(settings.chunkDelaySeconds),
              (0...2).contains(settings.paragraphPauseSeconds) else {
            throw ServiceFailure(
                code: "settings.invalid_chunk_timing",
                message: "Block and paragraph delays are outside the supported range."
            )
        }
        guard settings.modelUnloadDelaySeconds == 0
                || settings.modelUnloadDelaySeconds >= 30 else {
            throw ServiceFailure(
                code: "settings.invalid_unload_delay",
                message: "Model unload delay must be at least 30 seconds, or off."
            )
        }
        if settings.activeModelID != previousModelID {
            try await enqueueModelTransition(
                to: requestedModelID,
                settings: settings
            )
        } else {
            try settingsStore.update(settings)
        }
        if settings.httpEnabled != previousSettings.httpEnabled
            || settings.httpPort != previousSettings.httpPort {
            httpServiceError = nil
            httpServiceConfigurationHandler?(httpServiceConfiguration)
        }
        applyPlaybackSettings(settings)
        await synthesizer.updateConfiguration(
            chunkTarget: settings.chunkCharacterTarget,
            chunkDelay: settings.chunkDelaySeconds,
            paragraphPause: settings.paragraphPauseSeconds,
            idleUnloadDelay: settings.modelUnloadDelaySeconds
        )
        await textCleaner.update(
            options: Self.textCleaningOptions(from: settings)
        )
        enforceRetention()
        revision &+= 1
    }

    private func waitForPendingModelTransitions() async {
        while let task = modelTransitionTask {
            let sequence = modelTransitionSequence
            _ = await task.result
            guard sequence != modelTransitionSequence else { return }
        }
    }

    private func applyPlaybackSettings(_ settings: BackendSettingsSnapshot) {
        playback.rate = settings.playbackRate
        playback.volume = settings.volume
        playback.backwardSkipInterval = settings.rewindInterval
        playback.forwardSkipInterval = settings.forwardInterval
        playback.showTitleInNowPlaying = settings.showNowPlayingTitles
    }

    private var httpServiceConfiguration: HTTPServiceConfiguration {
        let settings = settingsStore.value
        return HTTPServiceConfiguration(
            isEnabled: settings.httpEnabled,
            port: settings.httpPort
        )
    }

    private static func textCleaningOptions(
        from settings: BackendSettingsSnapshot
    ) -> TextCleaningOptions {
        TextCleaningOptions(
            isEnabled: settings.textCleaningEnabled,
            stripMarkdown: settings.textCleaningStripMarkdown,
            stripHTML: settings.textCleaningStripHTML,
            stripCodeBlocks: settings.textCleaningStripCodeBlocks,
            stripSpecialCharacters: settings.textCleaningStripSpecialCharacters,
            normalizeWhitespace: settings.textCleaningNormalizeWhitespace
        )
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

        // A process launch must stay silent. Jobs interrupted by termination are
        // retained for status/history, but only a fresh user action may start
        // new speech after the service comes back.
        for (id, var job) in jobsByID where !job.state.isTerminal {
            job.state = .canceled
            job.finishedAt = .now
            jobsByID[id] = job
            if job.source != .preview {
                try? history.markIncomplete(id: id, state: .canceled)
            }
        }

        pendingJobs.removeAll(keepingCapacity: false)
        queuedJobIDs.removeAll(keepingCapacity: false)
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

    private func validatedVolume(_ value: Double) -> Double {
        min(max(value, 0), 2)
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

    private var queueBlockSnapshot: QueueBlockSnapshot? {
        guard !queuedJobIDs.isEmpty,
              let activeJob = activeJobID.flatMap({ jobsByID[$0] }) else {
            return nil
        }
        if playback.state == .paused {
            return QueueBlockSnapshot(
                reason: .playbackPaused,
                jobID: activeJob.id,
                message: "Playback is paused. Resume, clear, or interrupt it to continue the queue."
            )
        }
        switch activeJob.state {
        case .paused:
            return QueueBlockSnapshot(
                reason: .playbackPaused,
                jobID: activeJob.id,
                message: "Playback is paused. Resume, clear, or interrupt it to continue the queue."
            )
        case .awaitingConfirmation:
            return QueueBlockSnapshot(
                reason: .awaitingConfirmation,
                jobID: activeJob.id,
                message: "A speech job is waiting for long-text confirmation."
            )
        case .parsing, .preparing, .synthesizing, .buffering:
            return QueueBlockSnapshot(
                reason: .synthesisInProgress,
                jobID: activeJob.id,
                message: "Another speech job is still being prepared."
            )
        default:
            return nil
        }
    }
}

private extension ServiceSnapshot {
    func projectingPlayback(
        includesContent: Bool,
        includesWaveform: Bool,
        includesTiming: Bool,
        timingStartIndex: Int
    ) -> ServiceSnapshot {
        ServiceSnapshot(
            protocolVersion: protocolVersion,
            serviceVersion: serviceVersion,
            revision: revision,
            statusText: statusText,
            lastError: lastError,
            httpServiceError: httpServiceError,
            activeJob: activeJob,
            queuedJobs: queuedJobs,
            confirmationJobs: confirmationJobs,
            queueBlock: queueBlock,
            playback: PlaybackSnapshot(
                state: playback.state,
                elapsed: playback.elapsed,
                generatedDuration: playback.generatedDuration,
                estimatedDuration: playback.estimatedDuration,
                rate: playback.rate,
                volume: playback.volume,
                currentTitle: includesContent ? playback.currentTitle : "",
                modelID: includesContent ? playback.modelID : nil,
                amplitudes: includesWaveform ? playback.amplitudes : [],
                spokenText: includesContent ? playback.spokenText : "",
                spokenChunks: includesTiming
                    ? Array(playback.spokenChunks.dropFirst(timingStartIndex)) : [],
                includesContent: includesContent,
                includesWaveform: includesWaveform,
                includesTiming: includesTiming,
                timingStartIndex: timingStartIndex
            ),
            download: download,
            modelInstallError: modelInstallError,
            installedModelIDs: installedModelIDs,
            settings: settings,
            modelsRevision: modelsRevision,
            historyRevision: historyRevision,
            diagnosticsRevision: diagnosticsRevision,
            voicesRevision: voicesRevision,
            voiceStudio: voiceStudio
        )
    }
}
