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
        let fixture = PlaybackControllerFixture(usesLiveClock: true)
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: fixture.controller
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
    func replacementCancelsParkedConfirmationWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = PlaybackControllerFixture(usesLiveClock: true)
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: fixture.controller
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
                            text: String(
                                repeating: "First pending speech. ",
                                count: 5_000
                            ),
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
                            text: String(
                                repeating: "Second pending speech. ",
                                count: 5_000
                            ),
                            source: .frontend
                        )
                    )
                )
            )
        )

        try await waitForState(
            .awaitingConfirmation,
            jobID: firstQueued.id,
            service: service
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: secondQueued.id,
            service: service
        )
        let queuedSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(
            Set(queuedSnapshot.confirmationJobs.map(\.id))
                == Set([active.id, firstQueued.id, secondQueued.id])
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
        try await waitForState(
            .awaitingConfirmation,
            jobID: replacement.id,
            service: service
        )
        let confirmedReplacementSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(confirmedReplacementSnapshot.activeJob == nil)
        #expect(
            confirmedReplacementSnapshot.confirmationJobs.map(\.id)
                == [replacement.id]
        )
        #expect(confirmedReplacementSnapshot.queuedJobs.isEmpty)

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
        let fixture = PlaybackControllerFixture(usesLiveClock: true)
        let service = try SayItBackendService(
            directories: directories,
            playback: fixture.controller
        )
        await service.start()
        try seedPlayingAudio(on: fixture, modelID: originalID.rawValue)

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
        #expect(fixture.controller.state == .idle)
        #expect(fixture.audioOutput.pauseEngineCount >= 1)
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
        let fixture = PlaybackControllerFixture()
        let service = try SayItBackendService(
            directories: directories,
            playback: fixture.controller
        )
        await service.start()
        try seedPlayingAudio(on: fixture, modelID: originalID.rawValue)
        var staleSettings = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        ).settings
        staleSettings.speakingPace = SpeakingPace.fast.rawValue

        let selection = Task {
            await service.handle(
                ServiceRequest(command: .selectModel(replacementID.rawValue))
            )
        }
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(
                PlaybackController.modelSwitchFadeDuration
            )
        }
        let settingsTask = Task {
            await service.handle(
                ServiceRequest(command: .updateSettings(staleSettings))
            )
        }
        await fixture.settle()
        #expect(
            fixture.clock.pendingSleepDurations.contains(
                PlaybackController.modelSwitchFadeDuration
            )
        )
        await fixture.advance(by: PlaybackController.modelSwitchFadeDuration)
        let settingsResponse = await settingsTask.value
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
        let fixture = PlaybackControllerFixture()
        let service = try SayItBackendService(
            directories: directories,
            playback: fixture.controller
        )
        await service.start()
        try seedPlayingAudio(on: fixture, modelID: originalID.rawValue)

        let selection = Task {
            await service.handle(
                ServiceRequest(command: .selectModel(replacementID.rawValue))
            )
        }
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(
                PlaybackController.modelSwitchFadeDuration
            )
        }
        let rateTask = Task {
            await service.handle(
                ServiceRequest(command: .setPlaybackRate(1.5))
            )
        }
        await fixture.settle()
        #expect(
            fixture.clock.pendingSleepDurations.contains(
                PlaybackController.modelSwitchFadeDuration
            )
        )
        await fixture.advance(by: PlaybackController.modelSwitchFadeDuration)
        let rateResponse = await rateTask.value
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
        #expect(fixture.controller.rate == 1.5)
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
        let fixture = PlaybackControllerFixture()
        let service = try SayItBackendService(
            directories: directories,
            playback: fixture.controller
        )
        await service.start()
        try seedPlayingAudio(on: fixture, modelID: originalID.rawValue)

        let firstSelection = Task {
            await service.handle(
                ServiceRequest(
                    command: .selectModel(firstReplacementID.rawValue)
                )
            )
        }
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(
                PlaybackController.modelSwitchFadeDuration
            )
        }
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
        #expect(fixture.controller.state == .idle)
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
            playback: PlaybackControllerFixture().controller
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
            playback: PlaybackControllerFixture().controller
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
        #expect(serviceSnapshot.activeJob == nil)
        #expect(
            serviceSnapshot.confirmationJobs.map(\.id) == [freshServiceJob.id]
        )
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

    private func seedPlayingAudio(
        on fixture: PlaybackControllerFixture,
        modelID: String
    ) throws {
        let id = UUID()
        fixture.controller.prepare(
            requestID: id,
            title: "Active Speech",
            estimatedDuration: 2,
            modelID: modelID
        )
        try fixture.enqueue(requestID: id, duration: 2)
        fixture.controller.finishBuffering()
    }
}
