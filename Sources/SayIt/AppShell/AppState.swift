import AppKit
import Foundation
import Observation
import SayItCore
import SayItProtocol
import SayItXPC
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let settings: AppSettings
    let playback = PlaybackController()
    let history = HistoryStore()
    let launchAtLogin = LaunchAtLoginController()
    let backgroundService = BackgroundServiceController()

    private let client = SayItXPCClient()
    private let migration = BackendMigrationCoordinator()
    private let updateChecker = UpdateChecker()
    private var pollingTask: Task<Void, Never>?
    private var settingsPushTask: Task<Void, Never>?
    private var lastModelsRevision: UInt64?
    private var lastHistoryRevision: UInt64?
    private var lastDiagnosticsRevision: UInt64?
    private var lastServiceRevision: UInt64?
    private var downloadByteCounts: [ModelID: Int64] = [:]

    private(set) var models: [ModelDescriptor]
    private(set) var installedModelIDs: Set<ModelID> = []
    private(set) var downloadProgress: ModelDownloadProgress?
    private(set) var requestedModelInstallID: ModelID?
    private(set) var statusText = "Connecting to service"
    private(set) var errorMessage: String?
    private(set) var needsLongTextConfirmation = false
    private(set) var diagnosticEvents: [DiagnosticEvent] = []
    private(set) var serviceSnapshot: ServiceSnapshot?
    private(set) var serviceConnection: ServiceConnectionState = .connecting
    private(set) var backendSettings = BackendSettingsSnapshot()
    private(set) var apiTokens: [APITokenMetadata] = []
    private(set) var oneTimeTokenSecret: String?
    private(set) var updateStatus = "Up to date"
    private(set) var availableUpdateURL: URL?
    var isShowingOnboarding: Bool

    private init() {
        settings = AppSettings()
        models = (try? ModelCatalogLoader().bundledCatalog().models) ?? []
        isShowingOnboarding = !settings.onboardingComplete
        settings.onBackendChange = { [weak self] in
            self?.scheduleBackendSettingsPush()
        }
        playback.commandHandler = { [weak self] command in
            self?.perform(command)
        }
    }

    func startup() async {
        do {
            try await migration.migrate(
                settings: settings.backendSnapshot()
            )
        } catch {
            presentError(
                "Existing Say It data could not be migrated. The original data was left unchanged."
            )
            serviceConnection = .offline
            return
        }

        if !backgroundService.isUserDisabled {
            await backgroundService.enable()
        }

        startPolling()
        if settings.checkForUpdates,
           settings.lastUpdateCheck.map({
               Date.now.timeIntervalSince($0) > 24 * 60 * 60
           }) ?? true {
            checkForUpdates()
        }
    }

    func readClipboard() {
        receive(
            PasteboardPayloadReader.payload(
                from: .general,
                source: .clipboard
            )
        )
    }

    func speakSample() {
        speakSample(
            "Say It turns the words on your Mac into calm, private audio."
        )
    }

    func speakSample(_ text: String) {
        submit(
            SpeechSubmission(
                text: text,
                source: .preview,
                modelID: settings.activeModelID.rawValue,
                voice: settings.activeVoice,
                language: settings.activeLanguage,
                voiceDescription: settings.voiceDescription,
                speakingPace: settings.speakingPace.rawValue,
                playbackRate: settings.playbackRate,
                queuePolicy: .interruptCurrent,
                permitsLongText: true
            )
        )
    }

    func receive(_ payload: TextSourcePayload) {
        let submission: SpeechSubmission
        if let html = payload.html {
            submission = makeSubmission(
                text: payload.plainText ?? String(decoding: html, as: UTF8.self),
                format: .html,
                representationData: html,
                source: payload.source
            )
        } else if let richText = payload.richText {
            submission = makeSubmission(
                text: payload.plainText ?? "",
                format: .richText,
                representationData: richText,
                source: payload.source
            )
        } else {
            submission = makeSubmission(
                text: payload.plainText ?? "",
                format: .plainText,
                source: payload.source
            )
        }
        submit(submission)
    }

    func confirmLongText() {
        guard let id = serviceSnapshot?.activeJob?.id else { return }
        perform(.confirmJob(id))
    }

    func cancelLongText() {
        guard let id = serviceSnapshot?.activeJob?.id else { return }
        perform(.cancelJob(id))
    }

    func cancelCurrentRequest(preserveHistory: Bool = true) {
        _ = preserveHistory
        perform(.clear)
    }

    func clearCurrentSpeech() {
        perform(.clear)
    }

    func installModel(_ id: ModelID) {
        guard isServiceOnline else {
            presentError(
                "The background service is not ready. Try again in a moment."
            )
            return
        }
        guard requestedModelInstallID == nil else { return }

        requestedModelInstallID = id
        Task {
            do {
                let response = try await send(.installModel(id.rawValue))
                try requireSuccess(response)
            } catch {
                requestedModelInstallID = nil
                presentError(error.localizedDescription)
            }
        }
    }

    func downloadByteCount(for model: ModelDescriptor) -> Int64 {
        downloadByteCounts[model.id] ?? model.downloadByteCount
    }

    func cancelModelInstall() {
        requestedModelInstallID = nil
        perform(.cancelModelInstall)
    }

    func selectModel(_ model: ModelDescriptor) {
        perform(.selectModel(model.id.rawValue))
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
        perform(.removeModel(model.id.rawValue))
    }

    func addCommunityModel(
        repository: String,
        revision: String?,
        token: String
    ) async -> Bool {
        do {
            let response = try await send(
                .addCommunityModel(
                    repository: repository,
                    revision: revision?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nilIfEmpty,
                    accessToken: token.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nilIfEmpty
                )
            )
            try requireSuccess(response)
            await refreshModels()
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
        do {
            let bookmark = try source.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            perform(.importLocalModel(bookmark: bookmark))
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
        statusText = "Needs attention"
    }

    func clearError() {
        errorMessage = nil
        perform(.clearError)
    }

    func finishOnboarding() {
        guard !installedModelIDs.isEmpty else { return }
        settings.onboardingComplete = true
        isShowingOnboarding = false
    }

    func showOnboarding() {
        isShowingOnboarding = true
    }

    func onboardingWindowDidClose() {
        isShowingOnboarding = false
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
        perform(.replayHistory(item.id))
    }

    func regenerate(_ item: HistoryItemSnapshot) {
        perform(.regenerateHistory(item.id))
    }

    func togglePinned(_ item: HistoryItemSnapshot) {
        perform(.toggleHistoryPinned(item.id))
    }

    func export(_ item: HistoryItemSnapshot, kind: ExportKind) {
        if kind == .text {
            save(
                ExportedFile(
                    filename: "\(safeFilename(item.title)).txt",
                    contentType: "text/plain; charset=utf-8",
                    data: Data(item.cleanedText.utf8)
                )
            )
            return
        }
        Task {
            do {
                let response = try await send(
                    .exportHistory(item.id, format: kind.rawValue)
                )
                guard case .file(let file) = response else {
                    try requireSuccess(response)
                    return
                }
                save(file)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    func deleteHistoryItem(_ item: HistoryItemSnapshot) {
        perform(.deleteHistory(item.id))
    }

    func clearHistory() {
        perform(.clearHistory)
    }

    func refreshDiagnostics() {
        Task {
            await loadDiagnostics()
        }
    }

    func clearDiagnostics() {
        perform(.clearDiagnostics)
    }

    func exportDiagnostics() {
        Task {
            do {
                let response = try await send(.exportDiagnostics)
                guard case .file(let file) = response else {
                    try requireSuccess(response)
                    return
                }
                save(file)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    func refreshTokens() {
        Task {
            do {
                let response = try await send(.tokens)
                guard case .tokens(let tokens) = response else {
                    try requireSuccess(response)
                    return
                }
                apiTokens = tokens
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    func createToken(name: String, scopes: Set<APITokenScope>) async -> Bool {
        do {
            let response = try await send(
                .createToken(name: name, scopes: scopes)
            )
            guard case .createdToken(let creation) = response else {
                try requireSuccess(response)
                return false
            }
            oneTimeTokenSecret = creation.secret
            await loadTokens()
            return true
        } catch {
            presentError(error.localizedDescription)
            return false
        }
    }

    func dismissOneTimeToken() {
        oneTimeTokenSecret = nil
    }

    func revokeToken(_ token: APITokenMetadata) {
        perform(.revokeToken(token.id))
    }

    func updateHTTP(enabled: Bool, port: Int) {
        var snapshot = backendSettings
        snapshot.httpEnabled = enabled
        snapshot.httpPort = port
        backendSettings = snapshot
        perform(.updateSettings(snapshot))
    }

    func restartBackgroundService() {
        Task {
            await backgroundService.restart()
            await client.invalidate()
            serviceConnection = .connecting
        }
    }

    func checkForUpdates() {
        updateStatus = "Checking…"
        Task {
            do {
                let result = try await updateChecker.check(
                    currentVersion: applicationVersion
                )
                settings.lastUpdateCheck = .now
                switch result {
                case .unconfigured:
                    updateStatus = "Update feed not configured"
                    availableUpdateURL = nil
                case .current:
                    updateStatus = "Up to date"
                    availableUpdateURL = nil
                case .available(let version, let url):
                    updateStatus = "Version \(version) is available"
                    availableUpdateURL = url
                }
            } catch {
                updateStatus = "Couldn’t check for updates"
            }
        }
    }

    func openAvailableUpdate() {
        guard let availableUpdateURL else { return }
        NSWorkspace.shared.open(availableUpdateURL)
    }

    var applicationDisplayVersion: String {
        applicationVersion
    }

    var isServiceOnline: Bool {
        if case .online = serviceConnection {
            true
        } else {
            false
        }
    }

    var commandLineToolURL: URL? {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/sayit")
        return FileManager.default.isExecutableFile(atPath: url.path)
            ? url
            : nil
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            var retryDelay = Duration.milliseconds(250)
            while !Task.isCancelled {
                guard let self else { return }
                self.backgroundService.refresh()
                guard !self.backgroundService.isUserDisabled else {
                    self.serviceConnection = .disabled
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                do {
                    try await self.synchronizeServiceState()
                    retryDelay = .milliseconds(250)
                    try await Task.sleep(for: .milliseconds(100))
                } catch let failure as ServiceFailure
                    where failure.code == "protocol.version_mismatch" {
                    self.serviceConnection = .updateRequired
                    self.statusText = "Service update required"
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    self.serviceConnection = .offline
                    self.statusText = "Background service unavailable"
                    await self.client.invalidate()
                    try? await Task.sleep(for: retryDelay)
                    retryDelay = min(retryDelay * 2, .seconds(8))
                }
            }
        }
    }

    private func synchronizeServiceState() async throws {
        guard let lastServiceRevision else {
            try await reloadServiceSnapshot()
            return
        }
        let response = try await send(.events(after: lastServiceRevision))
        guard case .events(let events) = response else {
            try requireSuccess(response)
            throw ServiceFailure(
                code: "service.invalid_events",
                message: "The service returned an invalid event response."
            )
        }
        guard let event = events.last else { return }
        guard event.id == lastServiceRevision + 1 else {
            try await reloadServiceSnapshot()
            return
        }
        apply(event.snapshot)
    }

    private func reloadServiceSnapshot() async throws {
        let response = try await send(.snapshot)
        guard case .snapshot(let snapshot) = response else {
            try requireSuccess(response)
            throw ServiceFailure(
                code: "service.invalid_snapshot",
                message: "The service returned an invalid state snapshot."
            )
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: ServiceSnapshot) {
        lastServiceRevision = snapshot.revision
        serviceSnapshot = snapshot
        serviceConnection = .online(version: snapshot.serviceVersion)
        statusText = snapshot.statusText
        errorMessage = snapshot.lastError
        needsLongTextConfirmation =
            snapshot.activeJob?.state == .awaitingConfirmation
        installedModelIDs = Set(
            snapshot.installedModelIDs.map { ModelID($0) }
        )
        if let requestedModelInstallID,
           installedModelIDs.contains(requestedModelInstallID) {
            self.requestedModelInstallID = nil
        }
        playback.apply(snapshot.playback)
        applyDownload(snapshot.download)

        if backendSettings != snapshot.settings {
            backendSettings = snapshot.settings
            settings.apply(snapshot.settings)
            playback.backwardSkipInterval = snapshot.settings.rewindInterval
            playback.forwardSkipInterval = snapshot.settings.forwardInterval
            playback.showTitleInNowPlaying =
                snapshot.settings.showNowPlayingTitles
        }

        isShowingOnboarding = installedModelIDs.isEmpty
            || !settings.onboardingComplete

        if lastModelsRevision != snapshot.modelsRevision {
            lastModelsRevision = snapshot.modelsRevision
            Task { await refreshModels() }
        }
        if lastHistoryRevision != snapshot.historyRevision {
            lastHistoryRevision = snapshot.historyRevision
            Task { await refreshHistory() }
        }
        if lastDiagnosticsRevision != snapshot.diagnosticsRevision {
            lastDiagnosticsRevision = snapshot.diagnosticsRevision
            Task { await loadDiagnostics() }
        }
    }

    private func applyDownload(_ snapshot: DownloadSnapshot?) {
        guard let snapshot,
              let state = ModelInstallationState(
                rawValue: snapshot.state
              ) else {
            downloadProgress = nil
            return
        }
        downloadProgress = ModelDownloadProgress(
            modelID: ModelID(snapshot.modelID),
            state: state,
            completedBytes: snapshot.completedBytes,
            totalBytes: snapshot.totalBytes,
            bytesPerSecond: Int64(snapshot.bytesPerSecond)
        )
        if requestedModelInstallID == downloadProgress?.modelID {
            requestedModelInstallID = nil
        }
    }

    private func refreshModels() async {
        do {
            let response = try await send(.models)
            guard case .models(let snapshots) = response else {
                try requireSuccess(response)
                return
            }
            models = snapshots.map(\.descriptor)
            downloadByteCounts = Dictionary(
                uniqueKeysWithValues: snapshots.map {
                    (ModelID($0.id), $0.downloadByteCount)
                }
            )
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func refreshHistory() async {
        do {
            let response = try await send(.history)
            guard case .history(let snapshots) = response else {
                try requireSuccess(response)
                return
            }
            history.apply(snapshots)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func loadDiagnostics() async {
        do {
            let response = try await send(.diagnostics)
            guard case .diagnostics(let snapshots) = response else {
                try requireSuccess(response)
                return
            }
            diagnosticEvents = snapshots.map(\.event)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func loadTokens() async {
        do {
            let response = try await send(.tokens)
            guard case .tokens(let tokens) = response else {
                try requireSuccess(response)
                return
            }
            apiTokens = tokens
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func scheduleBackendSettingsPush() {
        settingsPushTask?.cancel()
        settingsPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.settings.backendSnapshot(
                httpEnabled: self.backendSettings.httpEnabled,
                httpPort: self.backendSettings.httpPort
            )
            self.backendSettings = snapshot
            do {
                let response = try await self.send(.updateSettings(snapshot))
                try self.requireSuccess(response)
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    private func submit(_ submission: SpeechSubmission) {
        Task {
            do {
                let response = try await send(.submit(submission))
                try requireSuccess(response)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func perform(_ command: ServiceCommand) {
        Task {
            do {
                let response = try await send(command)
                try requireSuccess(response)
                if case .revokeToken = command {
                    await loadTokens()
                }
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func send(
        _ command: ServiceCommand
    ) async throws -> ServiceResponse {
        do {
            return try await client.send(command)
        } catch {
            if error is SayItXPCClientError {
                requestedModelInstallID = nil
                serviceConnection = .offline
                statusText = "Background service unavailable"
                await client.invalidate()
            }
            throw error
        }
    }

    private func requireSuccess(_ response: ServiceResponse) throws {
        if case .failure(let failure) = response {
            throw failure
        }
    }

    private func makeSubmission(
        text: String,
        format: InputFormat,
        representationData: Data? = nil,
        source: TriggerSource
    ) -> SpeechSubmission {
        SpeechSubmission(
            text: text,
            inputFormat: format,
            representationData: representationData,
            source: source.speechJobSource,
            modelID: settings.activeModelID.rawValue,
            voice: settings.activeVoice,
            language: settings.activeLanguage,
            voiceDescription: settings.voiceDescription,
            speakingPace: settings.speakingPace.rawValue,
            playbackRate: settings.playbackRate,
            queuePolicy: .interruptCurrent
        )
    }

    private func save(_ file: ExportedFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.filename
        panel.allowedContentTypes = allowedContentTypes(for: file)
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            try file.data.write(to: destination, options: .atomic)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func allowedContentTypes(
        for file: ExportedFile
    ) -> [UTType] {
        switch file.filename.split(separator: ".").last?.lowercased() {
        case "m4a":
            [.mpeg4Audio]
        case "wav":
            [.wav]
        case "txt":
            [.plainText]
        default:
            [.json]
        }
    }

    private func safeFilename(_ title: String) -> String {
        title
            .replacing("/", with: "–")
            .replacing(":", with: "–")
    }

    private var applicationVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
