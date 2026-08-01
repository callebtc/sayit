import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@MainActor
struct SpeechQueuePolicyTests {
    @Test
    func httpServiceFailuresDoNotReplacePlayerWithAGlobalError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await service.start()

        var settings = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        ).settings
        settings.httpEnabled = true
        _ = await service.handle(
            ServiceRequest(command: .updateSettings(settings))
        )

        let message = "HTTP API could not start because the port is in use."
        await service.reportHTTPServiceError(message)

        let failedSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(failedSnapshot.lastError == nil)
        #expect(failedSnapshot.statusText == "Ready to speak")
        #expect(failedSnapshot.httpServiceError == message)
        #expect(!failedSnapshot.settings.httpEnabled)
    }

    @Test
    func queuePoliciesPreserveFIFOAndCancelReplacedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await service.start()

        let active = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(repeating: "Long speech. ", count: 5_000),
                            source: .frontend
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: active.id,
            service: service
        )

        let firstQueued = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "First queued speech",
                            source: .frontend
                        )
                    )
                )
            )
        )
        let secondQueued = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "Second queued speech",
                            source: .frontend
                        )
                    )
                )
            )
        )

        let queuedSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(
            queuedSnapshot.queuedJobs.map(\.id)
                == [firstQueued.id, secondQueued.id]
        )

        let replacement = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Replacement speech. ",
                                count: 3_000
                            ),
                            source: .frontend,
                            queuePolicy: .replaceAll
                        )
                    )
                )
            )
        )
        let replacementSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(replacementSnapshot.activeJob?.id == replacement.id)
        #expect(replacementSnapshot.queuedJobs.isEmpty)

        let jobs = try jobList(
            await service.handle(ServiceRequest(command: .jobs))
        )
        #expect(
            jobs.first(where: { $0.id == active.id })?.state == .canceled
        )
        #expect(
            jobs.first(where: { $0.id == firstQueued.id })?.state == .canceled
        )
        #expect(
            jobs.first(where: { $0.id == secondQueued.id })?.state == .canceled
        )
    }

    @Test
    func modelSwitchCancelsActiveAndQueuedWorkAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let directories = try AppDirectories.testing(root: root)
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let originalID = ModelID("kokoro-bf16")
        let replacementID = ModelID("kitten-mini-08")
        try seedInstallation(
            for: originalID,
            catalog: catalog,
            directories: directories
        )
        try seedInstallation(
            for: replacementID,
            catalog: catalog,
            directories: directories
        )
        let playback = MockPlaybackController()
        let service = try SayItBackendService(
            directories: directories,
            playback: playback
        )
        await service.start()

        let active = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(repeating: "Long speech. ", count: 5_000),
                            source: .frontend
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: active.id,
            service: service
        )
        let queued = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "Queued speech",
                            source: .frontend,
                            queuePolicy: .enqueue
                        )
                    )
                )
            )
        )

        let response = await service.handle(
            ServiceRequest(command: .selectModel(replacementID.rawValue))
        )
        guard case .accepted = response else {
            Issue.record("Expected the model switch to be accepted.")
            return
        }
        let switched = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        let jobs = try jobList(
            await service.handle(ServiceRequest(command: .jobs))
        )

        #expect(switched.settings.activeModelID == replacementID.rawValue)
        #expect(switched.activeJob == nil)
        #expect(switched.queuedJobs.isEmpty)
        #expect(jobs.first(where: { $0.id == active.id })?.state == .canceled)
        #expect(jobs.first(where: { $0.id == queued.id })?.state == .canceled)
        #expect(playback.modelSwitchStopCount == 1)
        await service.shutdown()
    }

    @Test
    func staleSettingsCannotUndoAnInFlightModelSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let directories = try AppDirectories.testing(root: root)
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let originalID = ModelID("kokoro-bf16")
        let replacementID = ModelID("kitten-mini-08")
        for id in [originalID, replacementID] {
            try seedInstallation(
                for: id,
                catalog: catalog,
                directories: directories
            )
        }
        let playback = MockPlaybackController()
        playback.modelSwitchStopDelay = .milliseconds(75)
        let service = try SayItBackendService(
            directories: directories,
            playback: playback
        )
        await service.start()
        var staleSettings = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        ).settings
        staleSettings.speakingPace = SpeakingPace.fast.rawValue

        let selection = Task {
            await service.handle(
                ServiceRequest(command: .selectModel(replacementID.rawValue))
            )
        }
        try await waitForModelSwitchStop(playback, count: 1)
        let settingsResponse = await service.handle(
            ServiceRequest(command: .updateSettings(staleSettings))
        )
        guard case .accepted = settingsResponse else {
            Issue.record("Expected the settings update to be accepted.")
            return
        }
        guard case .accepted = await selection.value else {
            Issue.record("Expected the model switch to be accepted.")
            return
        }

        let updated = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(updated.settings.activeModelID == replacementID.rawValue)
        #expect(updated.settings.speakingPace == SpeakingPace.fast.rawValue)
        await service.shutdown()
    }

    @Test
    func settingsWritersWaitForAnInFlightModelSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let directories = try AppDirectories.testing(root: root)
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let originalID = ModelID("kokoro-bf16")
        let replacementID = ModelID("kitten-mini-08")
        for id in [originalID, replacementID] {
            try seedInstallation(
                for: id,
                catalog: catalog,
                directories: directories
            )
        }
        let playback = MockPlaybackController()
        playback.modelSwitchStopDelay = .milliseconds(75)
        let service = try SayItBackendService(
            directories: directories,
            playback: playback
        )
        await service.start()

        let selection = Task {
            await service.handle(
                ServiceRequest(command: .selectModel(replacementID.rawValue))
            )
        }
        try await waitForModelSwitchStop(playback, count: 1)
        let rateResponse = await service.handle(
            ServiceRequest(command: .setPlaybackRate(1.5))
        )
        guard case .accepted = rateResponse,
              case .accepted = await selection.value else {
            Issue.record("Expected both serialized settings commands to succeed.")
            return
        }

        let updated = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(updated.settings.activeModelID == replacementID.rawValue)
        #expect(updated.settings.playbackRate == 1.5)
        #expect(playback.rate == 1.5)
        await service.shutdown()
    }

    @Test
    func rapidModelSwitchesKeepOnlyTheLatestSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let directories = try AppDirectories.testing(root: root)
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let originalID = ModelID("kokoro-bf16")
        let firstReplacementID = ModelID("kitten-mini-08")
        let finalReplacementID = ModelID("pocket-tts")
        for id in [originalID, firstReplacementID, finalReplacementID] {
            try seedInstallation(
                for: id,
                catalog: catalog,
                directories: directories
            )
        }
        let playback = MockPlaybackController()
        playback.modelSwitchStopDelay = .milliseconds(75)
        let service = try SayItBackendService(
            directories: directories,
            playback: playback
        )
        await service.start()

        let firstSelection = Task {
            await service.handle(
                ServiceRequest(
                    command: .selectModel(firstReplacementID.rawValue)
                )
            )
        }
        try await waitForModelSwitchStop(playback, count: 1)
        let finalResponse = await service.handle(
            ServiceRequest(command: .selectModel(finalReplacementID.rawValue))
        )
        guard case .accepted = finalResponse else {
            Issue.record("Expected the latest model switch to be accepted.")
            return
        }
        guard case .failure(let superseded) = await firstSelection.value else {
            Issue.record("Expected the earlier model switch to be superseded.")
            return
        }

        let updated = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        let diagnostics = try diagnosticList(
            await service.handle(ServiceRequest(command: .diagnostics))
        )
        #expect(updated.settings.activeModelID == finalReplacementID.rawValue)
        #expect(playback.modelSwitchStopCount == 2)
        #expect(superseded.code == "service.request_canceled")
        #expect(
            diagnostics.filter { $0.code == "model.switch_started" }.count == 2
        )
        #expect(
            diagnostics.filter { $0.code == "model.switch_canceled" }.count == 1
        )
        #expect(
            diagnostics.filter { $0.code == "model.switch_completed" }.count == 1
        )
        await service.shutdown()
    }

    @Test
    func unfinishedJobsDoNotStartAfterServiceRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let original = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await original.start()
        let active = try submittedJob(
            await original.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Persistent speech. ",
                                count: 5_000
                            ),
                            source: .service
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: active.id,
            service: original
        )
        let queued = try submittedJob(
            await original.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "Queued after the persistent job.",
                            source: .frontend
                        )
                    )
                )
            )
        )

        let restored = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await restored.start()
        let restoredSnapshot = try snapshot(
            await restored.handle(ServiceRequest(command: .snapshot))
        )
        #expect(restoredSnapshot.activeJob == nil)
        #expect(restoredSnapshot.queuedJobs.isEmpty)
        #expect(restoredSnapshot.playback.state == PlaybackState.idle.rawValue)

        let restoredJobs = try jobList(
            await restored.handle(ServiceRequest(command: .jobs))
        )
        #expect(
            restoredJobs.first(where: { $0.id == active.id })?.state
                == .canceled
        )
        #expect(
            restoredJobs.first(where: { $0.id == queued.id })?.state
                == .canceled
        )

        let freshServiceJob = try submittedJob(
            await restored.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Fresh service speech. ",
                                count: 5_000
                            ),
                            source: .service
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: freshServiceJob.id,
            service: restored
        )
        let serviceSnapshot = try snapshot(
            await restored.handle(ServiceRequest(command: .snapshot))
        )
        #expect(serviceSnapshot.activeJob?.id == freshServiceJob.id)
    }

    private func waitForState(
        _ state: SpeechJobState,
        jobID: UUID,
        service: SayItBackendService
    ) async throws {
        for _ in 0..<200 {
            let jobs = try jobList(
                await service.handle(ServiceRequest(command: .jobs))
            )
            if jobs.first(where: { $0.id == jobID })?.state == state {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The job did not reach \(state.rawValue).")
    }

    private func submittedJob(_ response: ServiceResponse) throws -> SpeechJob {
        guard case .job(let job) = response else {
            Issue.record("Expected a submitted job.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a submitted job."
            )
        }
        return job
    }

    private func snapshot(
        _ response: ServiceResponse
    ) throws -> ServiceSnapshot {
        guard case .snapshot(let snapshot) = response else {
            Issue.record("Expected a service snapshot.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a service snapshot."
            )
        }
        return snapshot
    }

    private func jobList(
        _ response: ServiceResponse
    ) throws -> [SpeechJob] {
        guard case .jobs(let jobs) = response else {
            Issue.record("Expected a job list.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a job list."
            )
        }
        return jobs
    }

    private func diagnosticList(
        _ response: ServiceResponse
    ) throws -> [DiagnosticSnapshot] {
        guard case .diagnostics(let diagnostics) = response else {
            Issue.record("Expected a diagnostic list.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a diagnostic list."
            )
        }
        return diagnostics
    }

    private func seedInstallation(
        for id: ModelID,
        catalog: ModelCatalog,
        directories: AppDirectories
    ) throws {
        let model = try #require(catalog.models.first { $0.id == id })
        let relativePath = "\(model.id.rawValue)/\(model.revision)"
        let directory = directories.models.appending(
            path: relativePath,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let installation = ModelInstallation(
            modelID: model.id,
            revision: model.revision,
            installedBytes: model.estimatedDiskBytes,
            verifiedAt: .now,
            dependenciesVerifiedAt: .now,
            dependenciesFingerprint: catalog.dependencyFingerprint(for: model),
            relativePath: relativePath
        )
        try JSONEncoder.sayIt.encode(installation).write(
            to: directory.appending(path: "installation.json"),
            options: .atomic
        )
    }

    private func waitForModelSwitchStop(
        _ playback: MockPlaybackController,
        count: Int
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while playback.modelSwitchStopCount < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the model switch to start.")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class MockPlaybackController: BackendPlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var currentModelID: String?
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
    var volume: Double = 1
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30
    private(set) var modelSwitchStopCount = 0
    var modelSwitchStopDelay: Duration?

    func prepare(
        requestID: UUID,
        title: String,
        estimatedDuration: TimeInterval,
        modelID: String?
    ) {
        currentTitle = title
        currentModelID = modelID
        self.estimatedDuration = estimatedDuration
        state = .preparing
    }

    func enqueue(_ chunk: AudioChunk) throws {
        generatedDuration += Double(chunk.samples.count) / chunk.sampleRate
        state = .buffering
    }

    func setSpokenText(_ text: String) {
        spokenText = text
        spokenChunks = []
    }

    func appendSpokenChunk(_ chunk: PlaybackTextChunk) {
        spokenChunks.append(chunk)
    }

    func play() {
        state = .playing
    }

    func pause() {
        state = .paused
    }

    func stop() {
        state = .idle
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        currentTitle = ""
        currentModelID = nil
    }

    func stopForModelSwitch() async {
        modelSwitchStopCount += 1
        if let modelSwitchStopDelay {
            try? await Task.sleep(for: modelSwitchStopDelay)
        }
        stop()
    }

    func seek(to seconds: TimeInterval) {
        elapsed = seconds
    }

    func skip(by seconds: TimeInterval) {
        elapsed += seconds
    }

    func finishBuffering() {
        state = .playing
    }

    func archive(
        using archive: AudioArchive
    ) async throws -> AudioArchiveResult {
        throw ServiceFailure(
            code: "test.archive_unavailable",
            message: "Archiving is not used by queue tests."
        )
    }

    func playFile(at url: URL, title: String, modelID: String?) throws {
        currentTitle = title
        currentModelID = modelID
        state = .playing
    }
}
