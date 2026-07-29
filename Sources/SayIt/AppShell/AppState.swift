import AppKit
import Foundation
import Observation
import OSLog
import SayItCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let settings: AppSettings
    let playback: PlaybackController
    let history: HistoryStore
    let launchAtLogin: LaunchAtLoginController

    private let directories: AppDirectories
    private let catalog: ModelCatalog
    private let modelManager: ModelManager
    private let synthesizer: SynthesisActor
    private let textCleaner = TextCleaner()
    private let audioArchive: AudioArchive
    private let diagnostics: DiagnosticRecorder
    private let tokenStore: KeychainTokenStore
    private let updateChecker = UpdateChecker()
    private let communityModelResolver = CommunityModelResolver()
    private let logger = Logger(
        subsystem: "com.sayit.mac",
        category: "application"
    )
    private var requestTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var activeRequest: SpeechRequest?
    private var pendingCleanedText: CleanedText?
    private var pendingSource: TriggerSource?

    private(set) var models: [ModelDescriptor]
    private(set) var installedModelIDs: Set<ModelID> = []
    private(set) var downloadProgress: ModelDownloadProgress?
    private(set) var currentChunkPreview = ""
    private(set) var currentChunkIndex = 0
    private(set) var totalChunks = 0
    private(set) var statusText = "Ready to speak"
    private(set) var errorMessage: String?
    private(set) var needsLongTextConfirmation = false
    var isShowingOnboarding: Bool
    private(set) var diagnosticEvents: [DiagnosticEvent] = []
    private(set) var updateStatus = "Up to date"
    private(set) var availableUpdateURL: URL?

    private init() {
        do {
            let directories = try AppDirectories.live()
            setenv("HF_HUB_CACHE", directories.hubCache.path, 1)
            let catalog = try ModelCatalogLoader().bundledCatalog()
            let settings = AppSettings()
            let history = try HistoryStore(directories: directories)
            let tokenStore = KeychainTokenStore()
            let manager = ModelManager(
                catalog: catalog,
                directories: directories,
                activeModelID: settings.activeModelID,
                tokenProvider: {
                    try await tokenStore.token()
                }
            )

            self.directories = directories
            self.catalog = catalog
            self.settings = settings
            self.history = history
            models = catalog.models
            playback = PlaybackController()
            launchAtLogin = LaunchAtLoginController()
            modelManager = manager
            self.tokenStore = tokenStore
            synthesizer = SynthesisActor { id in
                await manager.installedURL(for: id)
            }
            audioArchive = AudioArchive(directory: directories.historyAudio)
            diagnostics = DiagnosticRecorder(
                fileURL: directories.diagnostics.appending(path: "events.jsonl")
            )
            isShowingOnboarding = !settings.onboardingComplete
        } catch {
            fatalError("Say It could not initialize its local storage.")
        }
    }

    func startup() async {
        installedModelIDs = await modelManager.installedModelIDs()
        if !installedModelIDs.contains(settings.activeModelID),
           let first = models.first(where: {
               installedModelIDs.contains($0.id) && $0.isSelectable
           }) {
            settings.activeModelID = first.id
            settings.activeVoice = first.defaultVoice ?? ""
            settings.activeLanguage = first.defaultLanguage ?? ""
            try? await modelManager.select(first.id)
        }
        isShowingOnboarding = installedModelIDs.isEmpty
            || !settings.onboardingComplete
        do {
            try history.enforceRetention(
                period: settings.retentionPeriod,
                quotaBytes: settings.historyQuotaBytes
            )
        } catch {
            logger.error("History retention failed, code: history.retention_failed")
        }
        await diagnostics.record(
            DiagnosticEvent(
                severity: .info,
                category: .lifecycle,
                code: "application.started"
            )
        )
        playback.showTitleInNowPlaying = settings.showNowPlayingTitles
        playback.backwardSkipInterval = settings.rewindInterval
        playback.forwardSkipInterval = settings.forwardInterval
        if settings.checkForUpdates,
           settings.lastUpdateCheck.map({
               Date.now.timeIntervalSince($0) > 24 * 60 * 60
           }) ?? true {
            checkForUpdates()
        }
    }

    func readClipboard() {
        let payload = PasteboardPayloadReader.payload(
            from: .general,
            source: .clipboard
        )
        receive(payload)
    }

    func speakSample() {
        receive(
            TextSourcePayload(
                source: .clipboard,
                plainText: "Say It turns the words on your Mac into calm, private audio."
            )
        )
    }

    func receive(_ payload: TextSourcePayload) {
        cancelCurrentRequest(preserveHistory: true)
        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.process(payload)
        }
    }

    func confirmLongText() {
        guard let pendingCleanedText, let pendingSource else { return }
        needsLongTextConfirmation = false
        self.pendingCleanedText = nil
        self.pendingSource = nil
        requestTask = Task { [weak self] in
            await self?.beginSpeech(pendingCleanedText, source: pendingSource)
        }
    }

    func cancelLongText() {
        pendingCleanedText = nil
        pendingSource = nil
        needsLongTextConfirmation = false
        statusText = "Ready to speak"
    }

    func cancelCurrentRequest(preserveHistory: Bool = true) {
        requestTask?.cancel()
        requestTask = nil
        Task {
            await synthesizer.cancelCurrentRequest()
        }
        playback.stop()
        if preserveHistory, let activeRequest {
            try? history.markIncomplete(id: activeRequest.id, state: .canceled)
        }
        activeRequest = nil
        currentChunkPreview = ""
        statusText = "Ready to speak"
    }

    func installModel(_ id: ModelID) {
        guard downloadTask == nil else { return }
        errorMessage = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.install(id) { progress in
                    await self.updateDownloadProgress(progress)
                }
                await self.finishInstall(id)
            } catch is CancellationError {
                self.finishCancelledInstall()
            } catch {
                self.finishFailedInstall(error)
            }
        }
    }

    func downloadByteCount(for model: ModelDescriptor) -> Int64 {
        let modelType = model.modelType.lowercased()
        let dependencyBytes = catalog.dependencies
            .filter { $0.modelTypes.contains(modelType) }
            .reduce(Int64(0)) { total, dependency in
                total + dependency.files.reduce(Int64(0)) {
                    $0 + $1.byteCount
                }
            }
        return model.downloadByteCount + dependencyBytes
    }

    func cancelModelInstall() {
        guard let id = downloadProgress?.modelID else { return }
        downloadTask?.cancel()
        Task {
            await modelManager.cancelInstall(id)
        }
    }

    func selectModel(_ model: ModelDescriptor) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.synthesizer.cancelCurrentRequest()
                await self.synthesizer.unloadModel()
                try await self.modelManager.select(model.id)
                self.applyModelSelection(model)
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func updateLanguageForVoice(
        _ voice: String,
        model: ModelDescriptor
    ) {
        guard ["kokoro", "kokoro_tts"].contains(
            model.modelType.lowercased()
        ),
        let prefix = voice.first else {
            return
        }
        let languageByPrefix: [Character: String] = [
            "a": "en-US",
            "b": "en-GB",
            "e": "es",
            "f": "fr",
            "h": "hi",
            "i": "it",
            "j": "ja",
            "p": "pt",
            "z": "cmn"
        ]
        if let language = languageByPrefix[prefix] {
            settings.activeLanguage = language
        }
    }

    func removeModel(_ model: ModelDescriptor) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if self.settings.activeModelID == model.id {
                    guard let replacement = self.models.first(where: {
                        $0.id != model.id
                            && self.installedModelIDs.contains($0.id)
                            && $0.isSelectable
                    }) else {
                        self.presentError(
                            "Install another compatible model before deleting the active model."
                        )
                        return
                    }
                    await self.synthesizer.cancelCurrentRequest()
                    await self.synthesizer.unloadModel()
                    try await self.modelManager.select(replacement.id)
                    self.applyModelSelection(replacement)
                }
                try await self.modelManager.remove(model.id)
                self.models = await self.modelManager.models()
                await self.refreshInstalledModels()
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func addCommunityModel(
        repository: String,
        revision: String?,
        token: String
    ) async -> Bool {
        do {
            let normalizedToken = token.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalizedToken.isEmpty {
                try await tokenStore.save(normalizedToken)
            }
            let savedToken = try await tokenStore.token()
            let model = try await communityModelResolver.resolve(
                repository: repository,
                revision: revision,
                token: savedToken
            )
            try await modelManager.addCommunityModel(model)
            models = await modelManager.models()
            return true
        } catch {
            presentError(error.localizedDescription)
            return false
        }
    }

    func importLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose an MLX Audio Swift model folder containing config.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let hasAccess = source.startAccessingSecurityScopedResource()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if hasAccess {
                    source.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let model = try await self.communityModelResolver.resolveLocal(
                    directory: source
                )
                try await self.modelManager.importLocalModel(
                    model,
                    from: source
                )
                try await self.synthesizer.prepareDependencies(for: model)
                try await self.modelManager.markDependenciesVerified(model.id)
                self.models = await self.modelManager.models()
                await self.refreshInstalledModels()
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
        statusText = "Needs attention"
    }

    func clearError() {
        errorMessage = nil
        if playback.state == .idle {
            statusText = "Ready to speak"
        }
    }

    func finishOnboarding() {
        guard !installedModelIDs.isEmpty else { return }
        settings.onboardingComplete = true
        isShowingOnboarding = false
    }

    func showOnboarding() {
        isShowingOnboarding = true
    }

    func updateGlobalShortcut(_ shortcut: GlobalShortcut) {
        let previous = settings.globalShortcut
        do {
            try GlobalHotKeyManager.shared.register(shortcut)
            settings.shortcutKeyCode = shortcut.keyCode
            settings.shortcutModifiers = shortcut.carbonModifiers
            settings.shortcutKeyLabel = shortcut.keyLabel
        } catch {
            try? GlobalHotKeyManager.shared.register(previous)
            presentError("That shortcut is already in use.")
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func replay(_ item: HistoryItemSnapshot) {
        guard let url = history.audioURL(for: item) else {
            presentError("This item has no completed audio.")
            return
        }
        do {
            cancelCurrentRequest(preserveHistory: true)
            try playback.playFile(at: url, title: item.title)
            statusText = "Playing"
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func regenerate(_ item: HistoryItemSnapshot) {
        receive(
            TextSourcePayload(
                source: .history,
                plainText: item.cleanedText
            )
        )
    }

    func togglePinned(_ item: HistoryItemSnapshot) {
        do {
            try history.togglePinned(id: item.id)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func export(_ item: HistoryItemSnapshot, kind: ExportKind) {
        let panel = NSSavePanel()
        let sanitizedTitle = item.title
            .replacing("/", with: "–")
            .replacing(":", with: "–")
        let date = item.createdAt.formatted(
            .dateTime.year().month().day()
        )
        panel.nameFieldStringValue = "Say It – \(sanitizedTitle) – \(date).\(kind.rawValue)"
        panel.allowedContentTypes = switch kind {
        case .m4a: [.mpeg4Audio]
        case .wav: [.wav]
        case .text: [.plainText]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .text:
                    try item.cleanedText.write(
                        to: destination,
                        atomically: true,
                        encoding: .utf8
                    )
                case .m4a:
                    guard let source = self.history.audioURL(for: item) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try FileManager.default.copyItem(
                        at: source,
                        to: destination
                    )
                case .wav:
                    guard let source = self.history.audioURL(for: item) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try await self.audioArchive.convertToWAV(
                        source: source,
                        destination: destination
                    )
                }
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func refreshDiagnostics() {
        Task { [weak self] in
            guard let self else { return }
            let events = await self.diagnostics.events()
            self.applyDiagnosticEvents(events)
        }
    }

    func clearDiagnostics() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.diagnostics.clear()
                self.applyDiagnosticEvents([])
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Say It Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let events = await self.diagnostics.events()
                let payload = DiagnosticExport(
                    generatedAt: .now,
                    applicationVersion: self.applicationVersion,
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: "Apple silicon",
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    installedModelIDs: self.installedModelIDs.sorted {
                        $0.rawValue < $1.rawValue
                    },
                    settings: DiagnosticExport.SettingsSnapshot(
                        historyRetention: self.settings.retentionPeriod.rawValue,
                        historyQuotaBytes: self.settings.historyQuotaBytes,
                        showTitlesInNowPlaying: self.settings.showNowPlayingTitles,
                        updateChecksEnabled: self.settings.checkForUpdates
                    ),
                    events: events
                )
                let data = try JSONEncoder.sayIt.encode(payload)
                try data.write(to: destination, options: .atomic)
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    func checkForUpdates() {
        updateStatus = "Checking…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.updateChecker.check(
                    currentVersion: self.applicationVersion
                )
                self.settings.lastUpdateCheck = .now
                switch result {
                case .unconfigured:
                    self.updateStatus = "Update feed not configured"
                    self.availableUpdateURL = nil
                case .current:
                    self.updateStatus = "Up to date"
                    self.availableUpdateURL = nil
                case .available(let version, let url):
                    self.updateStatus = "Version \(version) is available"
                    self.availableUpdateURL = url
                }
            } catch {
                self.updateStatus = "Couldn’t check for updates"
            }
        }
    }

    func openAvailableUpdate() {
        guard let availableUpdateURL else { return }
        NSWorkspace.shared.open(availableUpdateURL)
    }

    func deleteHistoryItem(_ item: HistoryItemSnapshot) {
        do {
            try history.remove(id: item.id)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func clearHistory() {
        do {
            try history.removeAll()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func process(_ payload: TextSourcePayload) async {
        do {
            statusText = "Cleaning text"
            let cleaned = try await textCleaner.ingest(payload)
            if cleaned.requiresLongTextConfirmation {
                pendingCleanedText = cleaned
                pendingSource = payload.source
                needsLongTextConfirmation = true
                statusText = "Long text"
                return
            }
            await beginSpeech(cleaned, source: payload.source)
        } catch is CancellationError {
            return
        } catch {
            presentError(error.localizedDescription)
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .warning,
                    category: .ingestion,
                    code: "ingestion.failed"
                )
            )
        }
    }

    private func beginSpeech(
        _ cleaned: CleanedText,
        source: TriggerSource
    ) async {
        guard let model = models.first(where: {
            $0.id == settings.activeModelID
        }) else {
            presentError("Choose a speech model in Settings.")
            return
        }
        guard installedModelIDs.contains(model.id) else {
            pendingCleanedText = cleaned
            pendingSource = source
            isShowingOnboarding = true
            presentError("Download \(model.displayName) before speaking.")
            return
        }

        let request = SpeechRequest(
            cleanedText: cleaned,
            model: model,
            voice: settings.activeVoice.isEmpty ? model.defaultVoice : settings.activeVoice,
            language: settings.activeLanguage.isEmpty
                ? model.defaultLanguage
                : settings.activeLanguage,
            voiceDescription: settings.voiceDescription,
            source: source
        )
        activeRequest = request
        do {
            try history.begin(request)
        } catch {
            logger.error("History begin failed, code: history.begin_failed")
        }

        playback.rate = settings.playbackRate
        playback.prepare(
            requestID: request.id,
            title: request.cleanedText.title,
            estimatedDuration: Double(request.cleanedText.characterCount) / 14
        )
        statusText = "Preparing speech"
        errorMessage = nil

        let stream = await synthesizer.synthesize(request)
        do {
            for try await event in stream {
                try Task.checkCancellation()
                try await handle(event, request: request)
            }
        } catch is CancellationError {
            try? history.markIncomplete(id: request.id, state: .canceled)
        } catch {
            playback.stop()
            try? history.markIncomplete(
                id: request.id,
                state: .failed,
                code: "synthesis.failed"
            )
            presentError(error.localizedDescription)
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .error,
                    category: .synthesis,
                    code: "synthesis.failed",
                    modelID: request.model.id
                )
            )
        }
    }

    private func handle(
        _ event: SynthesisEvent,
        request: SpeechRequest
    ) async throws {
        switch event {
        case .loadingModel:
            statusText = "Loading \(request.model.displayName)"
        case .modelLoaded:
            statusText = "Preparing speech"
        case .chunkStarted(let index, let total, let preview):
            currentChunkIndex = index + 1
            totalChunks = total
            currentChunkPreview = preview
        case .audio(let chunk):
            try playback.enqueue(chunk)
            if playback.generatedDuration >= 1.2,
               playback.state != .playing {
                playback.play()
                statusText = "Playing"
            }
        case .metrics(let metrics):
            await diagnostics.record(
                DiagnosticEvent(
                    severity: .info,
                    category: .synthesis,
                    code: "synthesis.chunk_completed",
                    modelID: request.model.id,
                    durationMilliseconds: Int(
                        metrics.generationDuration * 1_000
                    ),
                    numericValue: metrics.realTimeFactor
                )
            )
        case .completed:
            playback.finishBuffering()
            statusText = "Playing"
            let archive = try await playback.archive(using: audioArchive)
            try history.complete(
                id: request.id,
                duration: archive.duration,
                audioRelativePath: archive.relativePath,
                audioByteCount: archive.byteCount
            )
            activeRequest = nil
            currentChunkPreview = ""
        case .cancelled:
            try? history.markIncomplete(id: request.id, state: .canceled)
        }
    }

    private func updateDownloadProgress(_ progress: ModelDownloadProgress) {
        downloadProgress = progress
        statusText = progress.state == .verifying
            ? "Verifying model"
            : "Downloading model"
    }

    private func finishInstall(_ id: ModelID) async {
        downloadTask = nil
        downloadProgress = nil
        if let model = models.first(where: { $0.id == id }) {
            statusText = "Preparing offline speech resources"
            do {
                try await synthesizer.prepareDependencies(for: model)
                try await modelManager.markDependenciesVerified(id)
            } catch {
                presentError(
                    "The model was downloaded, but its offline speech resources are incomplete."
                )
                return
            }
        }
        await refreshInstalledModels()
        let activeModelIsInstalled = installedModelIDs.contains(
            settings.activeModelID
        )
        if !activeModelIsInstalled,
           let model = models.first(where: { $0.id == id }) {
            do {
                try await modelManager.select(id)
                applyModelSelection(model)
            } catch {
                presentError(error.localizedDescription)
                return
            }
        }
        settings.onboardingComplete = true
        statusText = "Ready to speak"
        if let pendingCleanedText, let pendingSource {
            self.pendingCleanedText = nil
            self.pendingSource = nil
            await beginSpeech(pendingCleanedText, source: pendingSource)
        }
    }

    private func finishCancelledInstall() {
        downloadTask = nil
        if let current = downloadProgress {
            downloadProgress = ModelDownloadProgress(
                modelID: current.modelID,
                state: .paused,
                completedBytes: current.completedBytes,
                totalBytes: current.totalBytes,
                bytesPerSecond: 0
            )
        }
        statusText = "Download paused"
    }

    private func finishFailedInstall(_ error: Error) {
        downloadTask = nil
        presentError(error.localizedDescription)
    }

    private func refreshInstalledModels() async {
        installedModelIDs = await modelManager.installedModelIDs()
    }

    private func applyModelSelection(_ model: ModelDescriptor) {
        settings.activeModelID = model.id
        settings.activeVoice = model.defaultVoice ?? ""
        settings.activeLanguage = model.defaultLanguage ?? ""
        statusText = "Ready to speak"
    }

    private func applyDiagnosticEvents(_ events: [DiagnosticEvent]) {
        diagnosticEvents = events
    }

    var applicationDisplayVersion: String {
        applicationVersion
    }

    private var applicationVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
    }
}
