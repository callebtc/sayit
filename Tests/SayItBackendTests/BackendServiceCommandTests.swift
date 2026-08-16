import CryptoKit
import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Backend service commands", .serialized)
@MainActor
struct BackendServiceCommandTests {
    @Test("Lifecycle, protocol, event, and error commands remain coherent")
    func lifecycleAndErrors() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        let beforeStart = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(beforeStart.revision != 0)
        #expect(beforeStart.statusText == "Starting service")

        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(started.statusText == "Ready to speak")
        #expect(started.serviceVersion == "test-version")
        #expect(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: started.revision))
                )
            ).isEmpty
        )
        #expect(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: 0))
                )
            ).last?.snapshot.playback.includesContent == true
        )

        let mismatch = await fixture.service.handle(
            .init(protocolVersion: -1, command: .snapshot)
        )
        #expect(
            try failure(mismatch).code == "protocol.version_mismatch"
        )

        await fixture.service.reportServiceError("Transport failed")
        let failureEvents = try events(
            await fixture.service.handle(
                .init(command: .events(after: started.revision))
            )
        )
        #expect(failureEvents.last?.snapshot.playback.includesContent == true)
        let failed = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(failed.statusText == "Needs attention")
        #expect(failed.lastError == "Transport failed")

        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .clearError))
            )
        )
        let cleared = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(cleared.lastError == nil)
        #expect(cleared.statusText == "Ready to speak")
    }

    @Test("Waiting event requests resume when service state changes")
    func waitingEventsResumeOnRevision() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let waitingResponse = Task { @MainActor in
            await fixture.service.handle(
                .init(
                    command: .waitForEvents(
                        after: started.revision,
                        playbackInterval: 1
                    )
                )
            )
        }
        await Task.yield()
        await fixture.service.reportServiceError("Transport failed")

        let received = try events(await waitingResponse.value)
        #expect(received.last?.id ?? 0 > started.revision)
        #expect(received.last?.snapshot.lastError == "Transport failed")
        #expect(received.last?.snapshot.playback.includesContent == false)
    }

    @Test("Canceling a waiting event request returns promptly")
    func waitingEventsHonorCancellation() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let waitingResponse = Task { @MainActor in
            await fixture.service.handle(
                .init(
                    command: .waitForEvents(
                        after: started.revision,
                        playbackInterval: 1
                    )
                )
            )
        }
        await Task.yield()
        waitingResponse.cancel()

        let response = await waitingResponse.value
        #expect(try failure(response).code == "service.request_canceled")
    }

    @Test("A revision from an earlier service process resynchronizes immediately")
    func waitingEventsResynchronizeFutureRevision() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        let earlierProcessRevision = started.revision &+ 1_000

        let waitingResponse = Task { @MainActor in
            await fixture.service.handle(
                .init(
                    command: .waitForEvents(
                        after: earlierProcessRevision,
                        playbackInterval: 1
                    )
                )
            )
        }
        await Task.yield()
        await fixture.service.reportServiceError("Transport failed")

        let received = try events(await waitingResponse.value)
        guard let event = received.first else {
            Issue.record("Expected a resynchronization event")
            return
        }
        #expect(received.count == 1)
        #expect(event.id == started.revision)
        #expect(event.id < earlierProcessRevision)
        #expect(event.snapshot.statusText == "Ready to speak")
        #expect(event.snapshot.playback.includesContent)
    }

    @Test("Immediate waiting-event resynchronization includes playback content")
    func waitingEventsImmediateResynchronizationIncludesContent() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        await fixture.service.reportServiceError("Transport failed")

        let response = await fixture.service.handle(
            .init(
                command: .waitForEvents(
                    after: started.revision,
                    playbackInterval: 1
                )
            )
        )
        let event = try #require(try events(response).first)

        #expect(event.snapshot.lastError == "Transport failed")
        #expect(event.snapshot.playback.includesContent)
    }

    @Test("One service revision builds one event snapshot for all readers")
    func eventSnapshotsAreCachedPerRevision() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let started = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        let buildsBefore = fixture.service.eventSnapshotBuildCount
        await fixture.service.reportServiceError("Transport failed")

        let first = try events(
            await fixture.service.handle(
                .init(command: .events(after: started.revision))
            )
        )
        let second = try events(
            await fixture.service.handle(
                .init(command: .events(after: started.revision))
            )
        )

        #expect(first.first?.id == second.first?.id)
        #expect(fixture.service.eventSnapshotBuildCount == buildsBefore + 1)
    }

    @Test("Active playback emits a bounded cadence heartbeat")
    func activePlaybackCadenceHeartbeat() async throws {
        let sleepRecorder = BackendEventSleepRecorder()
        let fixture = try ServiceFixture { duration in
            await sleepRecorder.record(duration)
        }
        defer { fixture.remove() }
        await fixture.service.start()
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .play))
            )
        )
        let playing = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let response = await fixture.service.handle(
            .init(
                command: .waitForEvents(
                    after: playing.revision,
                    playbackInterval: 0.01
                )
            )
        )
        let heartbeat = try #require(try events(response).first)

        #expect(heartbeat.id > playing.revision)
        #expect(heartbeat.snapshot.playback.state == "playing")
        #expect(
            await sleepRecorder.recordedDurations() == [.milliseconds(100)]
        )
    }

    @Test("Idle event heartbeat does not synthesize a revision")
    func idleEventHeartbeatIsSilent() async throws {
        let sleepRecorder = BackendEventSleepRecorder()
        let fixture = try ServiceFixture { duration in
            await sleepRecorder.record(duration)
        }
        defer { fixture.remove() }
        await fixture.service.start()
        let idle = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let response = await fixture.service.handle(
            .init(
                command: .waitForEvents(
                    after: idle.revision,
                    playbackInterval: 0.25
                )
            )
        )

        #expect(try events(response).isEmpty)
        #expect(
            await sleepRecorder.recordedDurations() == [.seconds(30)]
        )
        let afterHeartbeat = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(afterHeartbeat.revision == idle.revision)
    }

    @Test("A playback transition during the cadence publishes its final state")
    func playbackTransitionDuringCadencePublishes() async throws {
        let sleepGate = BackendEventSleepGate()
        let fixture = try ServiceFixture { duration in
            try await sleepGate.sleep(duration)
        }
        defer { fixture.remove() }
        await fixture.service.start()
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .play))
            )
        )
        let playing = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let response = Task { @MainActor in
            await fixture.service.handle(
                .init(
                    command: .waitForEvents(
                        after: playing.revision,
                        playbackInterval: 0.25
                    )
                )
            )
        }
        await sleepGate.waitUntilSleeping()
        fixture.playback.finishForTesting()
        await sleepGate.resume()

        let event = try #require(try events(await response.value).first)
        #expect(event.id > playing.revision)
        #expect(event.snapshot.playback.state == "finished")
    }

    @Test("A playback transition between requests publishes immediately")
    func playbackTransitionBetweenRequestsPublishes() async throws {
        let sleepRecorder = BackendEventSleepRecorder()
        let fixture = try ServiceFixture { duration in
            await sleepRecorder.record(duration)
        }
        defer { fixture.remove() }
        await fixture.service.start()
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .play))
            )
        )
        let playing = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        fixture.playback.finishForTesting()

        let response = await fixture.service.handle(
            .init(
                command: .waitForEvents(
                    after: playing.revision,
                    playbackInterval: 0.25
                )
            )
        )
        let event = try #require(try events(response).first)

        #expect(event.id > playing.revision)
        #expect(event.snapshot.playback.state == "finished")
        #expect(await sleepRecorder.recordedDurations().isEmpty)
    }

    @Test("External playback controls wake paused event requests")
    func externalPlaybackControlsWakePausedEventRequests() async throws {
        let sleepGate = BackendEventSleepGate()
        let fixture = try ServiceFixture { duration in
            try await sleepGate.sleep(duration)
        }
        defer { fixture.remove() }
        await fixture.service.start()
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .play))
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .pause))
            )
        )
        let paused = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        let response = Task { @MainActor in
            await fixture.service.handle(
                .init(
                    command: .waitForEvents(
                        after: paused.revision,
                        playbackInterval: 0.25
                    )
                )
            )
        }
        await sleepGate.waitUntilSleeping()
        fixture.playback.play()
        fixture.playback.notifyExternalControl()

        let event = try #require(try events(await response.value).first)
        await sleepGate.resume()
        #expect(event.id > paused.revision)
        #expect(event.snapshot.playback.state == "playing")
    }

    @Test("History mutations publish a service event")
    func historyMutationsPublishRevision() async throws {
        let fixture = try ServiceFixture(seedVoiceAndHistory: true)
        defer { fixture.remove() }
        await fixture.service.start()
        let historyID = try #require(fixture.historyID)
        let before = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .toggleHistoryPinned(historyID))
                )
            )
        )
        let published = try events(
            await fixture.service.handle(
                .init(command: .events(after: before.revision))
            )
        )

        let event = try #require(published.first)
        #expect(event.id > before.revision)
        #expect(event.snapshot.historyRevision > before.historyRevision)

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .deleteHistory(historyID))
                )
            )
        )
        let deletion = try #require(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: event.id))
                )
            ).first
        )
        #expect(deletion.id > event.id)
        #expect(
            deletion.snapshot.historyRevision
                > event.snapshot.historyRevision
        )

        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .clearHistory))
            )
        )
        let cleared = try #require(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: deletion.id))
                )
            ).first
        )
        #expect(cleared.id > deletion.id)
        #expect(
            cleared.snapshot.historyRevision
                > deletion.snapshot.historyRevision
        )
    }

    @Test("Clearing diagnostics publishes a service event")
    func clearingDiagnosticsPublishesRevision() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let before = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .clearDiagnostics))
            )
        )
        let event = try #require(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: before.revision))
                )
            ).first
        )

        #expect(event.id > before.revision)
        #expect(
            event.snapshot.diagnosticsRevision
                > before.diagnosticsRevision
        )
    }

    @Test("Playback commands forward state and validate rates")
    func playbackCommands() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()

        #expect(
            isAccepted(await fixture.service.handle(.init(command: .play)))
        )
        #expect(fixture.playback.playCount == 1)
        #expect(
            isAccepted(await fixture.service.handle(.init(command: .pause)))
        )
        #expect(fixture.playback.pauseCount == 1)
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .seek(12.5)))
            )
        )
        #expect(fixture.playback.elapsed == 12.5)
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .skip(-2.5)))
            )
        )
        #expect(fixture.playback.elapsed == 10)
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .setPlaybackRate(1.75))
                )
            )
        )
        #expect(fixture.playback.rate == 1.75)

        for rate in [0.49, 2.01, Double.nan, Double.infinity] {
            let response = await fixture.service.handle(
                .init(command: .setPlaybackRate(rate))
            )
            #expect(try failure(response).code == "playback.invalid_rate")
        }

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .setVolume(1.5))
                )
            )
        )
        #expect(fixture.playback.volume == 1.5)

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .setVolume(0))
                )
            )
        )
        #expect(fixture.playback.volume == 0)

        for volume in [-0.01, 2.01, Double.nan, Double.infinity] {
            let response = await fixture.service.handle(
                .init(command: .setVolume(volume))
            )
            #expect(try failure(response).code == "playback.invalid_volume")
        }

        #expect(
            isAccepted(await fixture.service.handle(.init(command: .clear)))
        )
        #expect(fixture.playback.stopCount >= 1)
    }

    @Test("Settings validation covers every backend constraint")
    func settingsValidationAndApplication() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()
        let original = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        ).settings
        var httpConfigurations: [HTTPServiceConfiguration] = []
        fixture.service.setHTTPServiceConfigurationHandler {
            httpConfigurations.append($0)
        }
        #expect(
            httpConfigurations == [
                HTTPServiceConfiguration(
                    isEnabled: original.httpEnabled,
                    port: original.httpPort
                )
            ]
        )

        var invalidCases: [(BackendSettingsSnapshot, String)] = []
        var value = original
        value.activeModelID = "missing"
        invalidCases.append((value, "settings.model_not_found"))
        value = original
        value.speakingPace = 9
        invalidCases.append((value, "settings.invalid_speaking_pace"))
        value = original
        value.playbackRate = 0.4
        invalidCases.append((value, "settings.invalid_playback_rate"))
        value = original
        value.volume = -0.1
        invalidCases.append((value, "settings.invalid_volume"))
        value = original
        value.chunkCharacterTarget = 0
        invalidCases.append((value, "settings.invalid_chunk_size"))
        value = original
        value.chunkDelaySeconds = 11
        invalidCases.append((value, "settings.invalid_chunk_timing"))
        value = original
        value.paragraphPauseSeconds = 2.1
        invalidCases.append((value, "settings.invalid_chunk_timing"))
        value = original
        value.modelUnloadDelaySeconds = 29
        invalidCases.append((value, "settings.invalid_unload_delay"))
        value = original
        value.httpPort = 1_023
        invalidCases.append((value, "settings.invalid_http_port"))

        for (settings, code) in invalidCases {
            let response = await fixture.service.handle(
                .init(command: .updateSettings(settings))
            )
            #expect(try failure(response).code == code)
        }

        var updated = original
        updated.playbackRate = 1.5
        updated.volume = 0
        updated.rewindInterval = 7
        updated.forwardInterval = 42
        updated.showNowPlayingTitles = true
        updated.httpEnabled = true
        updated.httpPort = 49_999
        updated.chunkCharacterTarget = 1
        updated.chunkDelaySeconds = 0.2
        updated.paragraphPauseSeconds = 0.5
        updated.modelUnloadDelaySeconds = 0
        updated.textCleaningEnabled = false
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .updateSettings(updated))
                )
            )
        )
        #expect(fixture.playback.rate == 1.5)
        #expect(fixture.playback.volume == 0)
        #expect(fixture.playback.backwardSkipInterval == 7)
        #expect(fixture.playback.forwardSkipInterval == 42)
        #expect(fixture.playback.showTitleInNowPlaying)
        #expect(
            httpConfigurations.last
                == HTTPServiceConfiguration(
                    isEnabled: true,
                    port: 49_999
                )
        )
        #expect(
            try snapshot(
                await fixture.service.handle(.init(command: .snapshot))
            ).settings == updated
        )

        await fixture.service.reportHTTPServiceError("Port occupied")
        let httpFailure = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(httpFailure.httpServiceError == "Port occupied")
        #expect(!httpFailure.settings.httpEnabled)
        #expect(
            httpConfigurations.last
                == HTTPServiceConfiguration(
                    isEnabled: false,
                    port: 49_999
                )
        )
    }

    @Test("Submission validation and queue commands are deterministic")
    func submissionsAndQueueCommands() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()

        let invalidSubmissions = [
            SpeechSubmission(text: "   ", source: .frontend),
            SpeechSubmission(
                text: "<speak>Hello</speak>",
                inputFormat: .ssml,
                source: .frontend
            ),
            SpeechSubmission(
                text: "Fallback text",
                inputFormat: .richText,
                source: .frontend
            )
        ]
        let expectedCodes = [
            "speech.empty_text",
            "speech.unsupported_input_format",
            "speech.invalid_rich_text"
        ]
        for (submission, code) in zip(invalidSubmissions, expectedCodes) {
            let response = await fixture.service.handle(
                .init(command: .submit(submission))
            )
            if code == "speech.invalid_rich_text" {
                let job = try submittedJob(response)
                try await waitForTerminalJob(
                    job.id,
                    service: fixture.service
                )
                let jobs = try jobList(
                    await fixture.service.handle(.init(command: .jobs))
                )
                #expect(
                    jobs.first(where: { $0.id == job.id })?.errorCode == code
                )
            } else {
                #expect(try failure(response).code == code)
            }
        }

        let long = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Long content sentence. ",
                                count: 5_000
                            ),
                            source: .frontend
                        )
                    )
                )
            )
        )
        try await waitForJobState(
            .awaitingConfirmation,
            id: long.id,
            service: fixture.service
        )
        let queued = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Second long content. ",
                                count: 5_000
                            ),
                            source: .http
                        )
                    )
                )
            )
        )
        try await waitForJobState(
            .awaitingConfirmation,
            id: queued.id,
            service: fixture.service
        )
        let confirmationSnapshot = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(confirmationSnapshot.activeJob == nil)
        #expect(confirmationSnapshot.queuedJobs.isEmpty)
        #expect(
            Set(confirmationSnapshot.confirmationJobs.map(\.id))
                == Set([long.id, queued.id])
        )

        let unknown = UUID()
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(command: .confirmJob(unknown))
                )
            ).code == "job.not_awaiting_confirmation"
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelJob(queued.id))
                )
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelJob(long.id))
                )
            )
        )
        let jobs = try jobList(
            await fixture.service.handle(.init(command: .jobs))
        )
        #expect(jobs.first(where: { $0.id == long.id })?.state == .canceled)
        #expect(jobs.first(where: { $0.id == queued.id })?.state == .canceled)
    }

    @Test("Long-text confirmation does not block playable speech")
    func confirmationJobsAreParkedOutsideTheActiveSlot() async throws {
        let fixture = try ServiceFixture(synthesizesAudio: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()

        let confirmation = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Confirm this long speech. ",
                                count: 5_000
                            ),
                            source: .frontend
                        )
                    )
                )
            )
        )
        _ = try await waitForServiceSnapshot(fixture.service) {
            $0.confirmationJobs.map(\.id).contains(confirmation.id)
        }

        let playable = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: "Play this while confirmation is pending.",
                            source: .commandLine,
                            queuePolicy: .enqueue
                        )
                    )
                )
            )
        )
        let playing = try await waitForServiceSnapshot(fixture.service) {
            $0.activeJob?.id == playable.id
                && $0.playback.state == PlaybackState.playing.rawValue
        }

        #expect(playing.confirmationJobs.map(\.id) == [confirmation.id])
        #expect(playing.queuedJobs.isEmpty)
        _ = await fixture.service.handle(.init(command: .cancelJob(confirmation.id)))
        _ = await fixture.service.handle(.init(command: .clear))
    }

    @Test("Paused playback reports its blocker and interrupt starts new speech")
    func pausedPlaybackCanBeInterruptedWithoutStrandingTheQueue() async throws {
        let fixture = try ServiceFixture(synthesizesAudio: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()

        let pausedJob = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(text: "Pause me.", source: .frontend)
                    )
                )
            )
        )
        _ = try await waitForServiceSnapshot(fixture.service) {
            $0.activeJob?.id == pausedJob.id
                && $0.playback.state == PlaybackState.playing.rawValue
        }
        _ = await fixture.service.handle(.init(command: .pause))

        let queued = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: "Wait behind the pause.",
                            source: .http,
                            queuePolicy: .enqueue
                        )
                    )
                )
            )
        )
        let blocked = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(blocked.activeJob?.id == pausedJob.id)
        #expect(blocked.queuedJobs.map(\.id) == [queued.id])
        #expect(blocked.queueBlock?.reason == .playbackPaused)

        let replacement = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: "Speak now.",
                            source: .commandLine,
                            queuePolicy: .replaceAll
                        )
                    )
                )
            )
        )
        let replaced = try await waitForServiceSnapshot(fixture.service) {
            $0.activeJob?.id == replacement.id
        }
        let jobs = try jobList(
            await fixture.service.handle(.init(command: .jobs))
        )

        #expect(replaced.queuedJobs.isEmpty)
        #expect(jobs.first(where: { $0.id == pausedJob.id })?.state == .canceled)
        #expect(jobs.first(where: { $0.id == queued.id })?.state == .canceled)
        _ = await fixture.service.handle(.init(command: .clear))
    }

    @Test("History replay replaces active and queued speech")
    func replayHistoryClearsSpeechWork() async throws {
        let fixture = try ServiceFixture(
            seedVoiceAndHistory: true,
            synthesizesAudio: true
        )
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()
        let historyID = try #require(fixture.historyID)

        let active = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(text: "Current speech.", source: .frontend)
                    )
                )
            )
        )
        _ = try await waitForServiceSnapshot(fixture.service) {
            $0.activeJob?.id == active.id
                && $0.playback.state == PlaybackState.playing.rawValue
        }
        _ = await fixture.service.handle(.init(command: .pause))
        let queued = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: "Queued speech.",
                            source: .http,
                            queuePolicy: .enqueue
                        )
                    )
                )
            )
        )

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .replayHistory(historyID))
                )
            )
        )
        let replaying = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        let jobs = try jobList(
            await fixture.service.handle(.init(command: .jobs))
        )

        #expect(replaying.activeJob == nil)
        #expect(replaying.queuedJobs.isEmpty)
        #expect(replaying.playback.state == PlaybackState.playing.rawValue)
        #expect(fixture.playback.playedFileTitle == "Saved title")
        #expect(jobs.first(where: { $0.id == active.id })?.state == .canceled)
        #expect(jobs.first(where: { $0.id == queued.id })?.state == .canceled)
    }

    @Test("A synthesis progress timeout fails the stalled job")
    func stalledSynthesisFailsInsteadOfOwningTheQueueForever() async throws {
        let gate = BackendSynthesisEventGate()
        let fixture = try ServiceFixture(
            synthesizesAudio: true,
            synthesisEventGate: gate,
            synthesisStallTimeout: .milliseconds(100)
        )
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()

        let stalled = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: String(repeating: "Stall after this chunk. ", count: 200),
                            source: .service,
                            permitsLongText: true
                        )
                    )
                )
            )
        )
        try await waitForTerminalJob(stalled.id, service: fixture.service)
        let jobs = try jobList(
            await fixture.service.handle(.init(command: .jobs))
        )

        #expect(jobs.first(where: { $0.id == stalled.id })?.state == .failed)
        #expect(
            jobs.first(where: { $0.id == stalled.id })?.errorCode
                == "synthesis.stalled"
        )
        await gate.releaseNext()
        await gate.releaseNext()
    }

    @Test("Synthesis forwards multiline source ranges without rematching text")
    func synthesisForwardsMultilineSourceRanges() async throws {
        let fixture = try ServiceFixture(synthesizesAudio: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()
        let text = """
        Intro sentence.

        Verse line one
        Verse line two

        Outro sentence.
        """

        _ = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: text,
                            source: .preview,
                            modelID: fixture.seedModelID,
                            permitsLongText: true
                        )
                    )
                )
            )
        )
        for _ in 0..<300 {
            guard fixture.playback.spokenChunks.isEmpty else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let ranges = fixture.playback.spokenChunks.map {
            $0.textStart..<$0.textEnd
        }
        let spokenText = fixture.playback.spokenText
        let spokenWords = ranges.flatMap { range in
            let lower = spokenText.index(
                spokenText.startIndex,
                offsetBy: range.lowerBound
            )
            let upper = spokenText.index(lower, offsetBy: range.count)
            return spokenText[lower..<upper]
                .split(whereSeparator: \.isWhitespace)
        }
        #expect(ranges.count == 1)
        #expect(spokenWords == text.split(whereSeparator: \.isWhitespace))
        #expect(
            fixture.playback.spokenChunks.map(\.audioStart)
                == [0]
        )

        _ = await fixture.service.handle(.init(command: .clear))
    }

    @Test("Repeated buffering audio publishes changed playback content")
    func repeatedBufferingAudioPublishesContent() async throws {
        let eventGate = BackendSynthesisEventGate()
        let fixture = try ServiceFixture(
            synthesizesAudio: true,
            synthesisEventGate: eventGate
        )
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()
        let text = String(repeating: "A complete sentence. ", count: 180)

        _ = try submittedJob(
            await fixture.service.handle(
                .init(
                    command: .submit(
                        SpeechSubmission(
                            text: text,
                            source: .preview,
                            modelID: fixture.seedModelID,
                            permitsLongText: true
                        )
                    )
                )
            )
        )
        for _ in 0..<300 {
            guard fixture.playback.generatedDuration < 1 else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.playback.generatedDuration == 1)
        let afterFirstChunk = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )

        await eventGate.releaseNext()
        for _ in 0..<300 {
            guard fixture.playback.generatedDuration < 2 else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.playback.generatedDuration == 2)
        let event = try #require(
            try events(
                await fixture.service.handle(
                    .init(command: .events(after: afterFirstChunk.revision))
                )
            ).first
        )

        #expect(event.snapshot.playback.generatedDuration == 2)
        #expect(event.snapshot.playback.includesContent)
        await eventGate.releaseNext()
        _ = await fixture.service.handle(.init(command: .clear))
    }

    @Test("Clipboard and selection submissions retain identical paragraphs")
    func richInputPathsRetainIdenticalParagraphs() async throws {
        let fixture = try ServiceFixture(synthesizesAudio: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()
        let plainText = "First sentence.\n\nLike this."
        let expectedText = "First sentence.\nLike this."
        let html = Data(
            "<article><span>First sentence.</span><span>Like this.</span></article>".utf8
        )

        for source in [SpeechJobSource.clipboard, .selection] {
            _ = try submittedJob(
                await fixture.service.handle(
                    .init(
                        command: .submit(
                            SpeechSubmission(
                                text: plainText,
                                inputFormat: .html,
                                representationData: html,
                                source: source,
                                modelID: fixture.seedModelID,
                                permitsLongText: true
                            )
                        )
                    )
                )
            )
            for _ in 0..<300 {
                guard fixture.playback.spokenText != expectedText else { break }
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(fixture.playback.spokenText == expectedText)
            _ = await fixture.service.handle(.init(command: .clear))
        }
    }

    @Test("Model, voice studio, and token validation return stable failures")
    func modelVoiceAndTokenFailures() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        await fixture.service.start()

        #expect(
            try models(
                await fixture.service.handle(.init(command: .models))
            ).isEmpty == false
        )
        for (command, code) in [
            (ServiceCommand.selectModel("missing"), "model.not_found"),
            (ServiceCommand.installModel("missing"), "model.not_found"),
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: "missing",
                        language: "en",
                        sampleText: "Sample"
                    )
                ),
                "model.not_found"
            ),
            (
                ServiceCommand.startVoiceClone(
                    VoiceCloneRequest(
                        recordingID: UUID(),
                        modelID: "missing",
                        language: "en",
                        transcript: "Transcript",
                        tuning: VoiceTuning()
                    )
                ),
                "model.not_found"
            ),
            (ServiceCommand.voicePreview(UUID()), "voice.preview_not_found"),
            (
                ServiceCommand.saveVoiceCandidate(
                    UUID(),
                    name: "Name",
                    tuning: VoiceTuning()
                ),
                "voice.preview_not_found"
            ),
            (
                ServiceCommand.saveVoiceClone(UUID(), name: "Name"),
                "voice.clone_not_ready"
            ),
            (ServiceCommand.selectVoice(UUID()), "voice.not_found"),
            (
                ServiceCommand.renameVoice(UUID(), name: "Name"),
                "voice.not_found"
            ),
            (
                ServiceCommand.updateVoiceTuning(UUID(), VoiceTuning()),
                "voice.not_found"
            ),
            (
                ServiceCommand.duplicateVoiceProfile(
                    UUID(),
                    name: "Name",
                    tuning: VoiceTuning()
                ),
                "voice.not_found"
            ),
            (
                ServiceCommand.previewVoiceProfile(
                    UUID(),
                    tuning: VoiceTuning(),
                    text: "Preview"
                ),
                "voice.not_found"
            ),
            (ServiceCommand.deleteVoice(UUID()), "voice.not_found"),
            (
                ServiceCommand.createToken(name: " ", scopes: [.stateRead]),
                "token.invalid_name"
            ),
            (
                ServiceCommand.createToken(name: "test", scopes: []),
                "token.empty_scopes"
            )
        ] {
            let response = await fixture.service.handle(.init(command: command))
            #expect(try failure(response).code == code)
        }

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelModelInstall)
                )
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelVoiceStudio)
                )
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .removeModel("missing"))
                )
            )
        )
        #expect(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: nil))
                )
            ).isEmpty
        )
    }

    @Test("Model downloads cancel, fail, restart, and finish setup before install")
    func modelDownloadCancellationAndRestart() async throws {
        let modelConfig = Data(#"{"model_type":"qwen3_tts"}"#.utf8)
        let modelWeights = Data([1, 2, 3, 4])
        let model = downloadTestModel(
            config: modelConfig,
            weights: modelWeights
        )
        let catalog = ModelCatalog(
            schemaVersion: 1,
            generatedAt: "test",
            models: [model]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestartableDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        RestartableDownloadURLProtocol.setHandler { _ in nil }
        let dependencyGate = DependencyPreparationGate()
        let fixture = try ServiceFixture(
            downloadCatalog: catalog,
            downloadSession: session,
            dependencyPreparationGate: dependencyGate
        )
        defer { fixture.remove() }
        await fixture.service.start()

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .installModel(model.id.rawValue))
                )
            )
        )
        _ = try await waitForServiceSnapshot(fixture.service) {
            $0.download?.state
                == ModelInstallationState.downloading.rawValue
        }

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelModelInstall)
                )
            )
        )
        let paused = try await waitForServiceSnapshot(fixture.service) {
            $0.download?.state == ModelInstallationState.paused.rawValue
        }
        #expect(paused.installedModelIDs.isEmpty)

        RestartableDownloadURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "about:blank")!,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data()
            )
        }
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .installModel(model.id.rawValue))
                )
            )
        )
        let failed = try await waitForServiceSnapshot(fixture.service) {
            $0.download?.state == ModelInstallationState.failed.rawValue
        }
        #expect(failed.modelInstallError?.modelID == model.id.rawValue)
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelModelInstall)
                )
            )
        )
        let dismissed = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(dismissed.download == nil)
        #expect(dismissed.modelInstallError == nil)

        RestartableDownloadURLProtocol.setHandler { request in
            let data = request.url?.lastPathComponent == "config.json"
                ? modelConfig
                : modelWeights
            return (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "about:blank")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(data.count)"]
                )!,
                data
            )
        }
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .installModel(model.id.rawValue))
                )
            )
        )

        for _ in 0..<400 {
            if await dependencyGate.hasEntered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await dependencyGate.hasEntered)
        let finishing = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(
            finishing.download?.state
                == ModelInstallationState.verifying.rawValue
        )
        #expect(finishing.download?.completedBytes == model.downloadByteCount)
        #expect(finishing.installedModelIDs.isEmpty)

        await dependencyGate.release()
        let completed = try await waitForServiceSnapshot(fixture.service) {
            $0.download == nil
                && $0.installedModelIDs.contains(model.id.rawValue)
        }
        #expect(completed.statusText == "Ready to speak")
    }

    @Test("Saved voice and history commands cover complete local lifecycles")
    func voiceAndHistoryLifecycles() async throws {
        let fixture = try ServiceFixture(seedVoiceAndHistory: true)
        defer { fixture.remove() }
        await fixture.service.start()
        let profileID = try #require(fixture.profileID)
        let historyID = try #require(fixture.historyID)

        #expect(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: fixture.seedModelID))
                )
            ).map(\.id) == [profileID]
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .selectVoice(profileID))
                )
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .renameVoice(
                            profileID,
                            name: "Golden Harbor"
                        )
                    )
                )
            )
        )
        #expect(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: nil))
                )
            ).first?.displayName == "Golden Harbor"
        )

        let historyItems = try history(
            await fixture.service.handle(.init(command: .history))
        )
        #expect(historyItems.map(\.id) == [historyID])
        let textFile = try exportedFile(
            await fixture.service.handle(
                .init(command: .exportHistory(historyID, format: "text"))
            )
        )
        #expect(textFile.contentType.hasPrefix("text/plain"))
        #expect(String(decoding: textFile.data, as: UTF8.self) == "Saved text")
        let audioFile = try exportedFile(
            await fixture.service.handle(
                .init(command: .exportHistory(historyID, format: "m4a"))
            )
        )
        #expect(audioFile.contentType == "audio/mp4")
        #expect(audioFile.data == Data([1, 2, 3]))
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .exportHistory(
                            historyID,
                            format: "invalid"
                        )
                    )
                )
            ).code == "history.unsupported_export_format"
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .replayHistory(historyID))
                )
            )
        )
        #expect(fixture.playback.playedFileTitle == "Saved title")
        #expect(fixture.playback.spokenText == "Saved text")
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .toggleHistoryPinned(historyID))
                )
            )
        )

        let diagnostics = try diagnosticList(
            await fixture.service.handle(.init(command: .diagnostics))
        )
        #expect(!diagnostics.isEmpty)
        let diagnosticFile = try exportedFile(
            await fixture.service.handle(.init(command: .exportDiagnostics))
        )
        #expect(diagnosticFile.contentType == "application/json")
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .clearDiagnostics)
                )
            )
        )

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .deleteVoice(profileID))
                )
            )
        )
        #expect(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: nil))
                )
            ).isEmpty
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .deleteHistory(historyID))
                )
            )
        )
        #expect(
            try history(
                await fixture.service.handle(.init(command: .history))
            ).isEmpty
        )
        #expect(
            isAccepted(
                await fixture.service.handle(.init(command: .clearHistory))
            )
        )
    }

    @Test("Playback snapshot reports the model that generated the audio")
    func playbackSnapshotReportsHistoryModel() async throws {
        let fixture = try ServiceFixture(seedVoiceAndHistory: true)
        defer { fixture.remove() }
        await fixture.service.start()
        let historyID = try #require(fixture.historyID)
        let itemModelID = try #require(
            try history(
                await fixture.service.handle(.init(command: .history))
            ).first?.modelID
        )

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .replayHistory(historyID))
                )
            )
        )
        #expect(fixture.playback.currentModelID == itemModelID)
        let playing = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(playing.playback.modelID == itemModelID)

        #expect(
            isAccepted(await fixture.service.handle(.init(command: .clear)))
        )
        let cleared = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(cleared.playback.modelID == nil)
    }

    @Test("Switching the playback model re-synthesizes the current audio")
    func switchPlaybackModelResynthesizesCurrentAudio() async throws {
        let fixture = try ServiceFixture(seedVoiceAndHistory: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        try fixture.seedInstallation(modelID: "kitten-mini-08")
        await fixture.service.start()
        let historyID = try #require(fixture.historyID)

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .replayHistory(historyID))
                )
            )
        )
        #expect(fixture.playback.currentModelID == "kokoro-bf16")

        let job = try submittedJob(
            await fixture.service.handle(
                .init(command: .switchPlaybackModel("kitten-mini-08"))
            )
        )
        #expect(job.source == .history)
        let switched = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(switched.settings.activeModelID == "kitten-mini-08")

        try await waitForTerminalJob(job.id, service: fixture.service)
        let requestedModelIDs = await fixture.synthesizer.requestedModelIDs
        #expect(requestedModelIDs == ["kitten-mini-08"])
        let unloadCount = await fixture.synthesizer.unloadCount
        #expect(unloadCount >= 1)
    }

    @Test("Switching the playback model without audio only selects the model")
    func switchPlaybackModelWithoutPlayback() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        try fixture.seedInstallation(modelID: "kitten-mini-08")
        await fixture.service.start()

        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .switchPlaybackModel("kitten-mini-08"))
                )
            )
        )
        let switched = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(switched.settings.activeModelID == "kitten-mini-08")
        #expect(switched.activeJob == nil)
        #expect(switched.queuedJobs.isEmpty)
        let requestedModelIDs = await fixture.synthesizer.requestedModelIDs
        #expect(requestedModelIDs.isEmpty)
    }

    @Test("Switching the playback model validates the target model")
    func switchPlaybackModelValidatesModel() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        await fixture.service.start()

        #expect(
            try failure(
                await fixture.service.handle(
                    .init(command: .switchPlaybackModel("missing"))
                )
            ).code == "model.not_found"
        )
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(command: .switchPlaybackModel("kitten-mini-08"))
                )
            ).code == "model.not_installed"
        )
    }

    @Test("Installed models exercise request-scoped voice resolution")
    func installedModelVoiceResolution() async throws {
        let fixture = try ServiceFixture(seedVoiceAndHistory: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        try fixture.seedInstallation(
            modelID: "qwen3-17b-voicedesign-8bit"
        )
        await fixture.service.start()
        let profileID = try #require(fixture.profileID)

        let cases: [(SpeechSubmission, String)] = [
            (
                SpeechSubmission(
                    text: "Conflicting selectors",
                    source: .frontend,
                    modelID: "kokoro-bf16",
                    voice: "af_heart",
                    voiceSelection: .automaticStable,
                    permitsLongText: true
                ),
                "voice.conflicting_selection"
            ),
            (
                SpeechSubmission(
                    text: "Unknown preset",
                    source: .frontend,
                    modelID: "kokoro-bf16",
                    voiceSelection: .preset("missing"),
                    permitsLongText: true
                ),
                "voice.preset_not_found"
            ),
            (
                SpeechSubmission(
                    text: "Unknown profile",
                    source: .frontend,
                    modelID: "kokoro-bf16",
                    voiceSelection: .profile(UUID()),
                    permitsLongText: true
                ),
                "voice.not_found"
            ),
            (
                SpeechSubmission(
                    text: "Profile mismatch",
                    source: .frontend,
                    modelID: "kokoro-bf16",
                    voiceSelection: .profile(profileID),
                    permitsLongText: true
                ),
                "voice.model_mismatch"
            ),
            (
                SpeechSubmission(
                    text: "Unsupported random mode",
                    source: .frontend,
                    modelID: "kokoro-bf16",
                    voiceSelection: .randomPerParagraph,
                    permitsLongText: true
                ),
                "voice.random_mode_unsupported"
            ),
            (
                SpeechSubmission(
                    text: "Missing requested model",
                    source: .frontend,
                    modelID: "missing",
                    permitsLongText: true
                ),
                "model.not_found"
            )
        ]

        for (submission, code) in cases {
            #expect(
                try await terminalErrorCode(
                    for: submission,
                    service: fixture.service
                ) == code
            )
        }

        let loadFailure = try await terminalErrorCode(
            for: SpeechSubmission(
                text: "Valid preset reaches model loading.",
                source: .frontend,
                modelID: "kokoro-bf16",
                voiceSelection: .automaticStable,
                playbackRate: 1.25,
                permitsLongText: true
            ),
            service: fixture.service
        )
        #expect(loadFailure == "synthesis.failed")
        #expect(fixture.playback.rate == 1.25)
        #expect(fixture.playback.spokenText == "Valid preset reaches model loading.")

        let localizedLoadFailure = try await terminalErrorCode(
            for: SpeechSubmission(
                text: "Japanese preset reaches model loading.",
                source: .frontend,
                modelID: "kokoro-bf16",
                voiceSelection: .preset("jf_alpha"),
                permitsLongText: true
            ),
            service: fixture.service
        )
        #expect(localizedLoadFailure == "synthesis.failed")
        #expect(await fixture.synthesizer.requestedLanguages.last == "ja")

        let designedVoiceFailure = try await terminalErrorCode(
            for: SpeechSubmission(
                text: "Curated description reaches model loading.",
                source: .frontend,
                modelID: "qwen3-17b-voicedesign-8bit",
                voiceSelection: .preset("Dramatic narrator"),
                voiceDescription: "This stale custom description is ignored.",
                permitsLongText: true
            ),
            service: fixture.service
        )
        #expect(designedVoiceFailure == "synthesis.failed")
        #expect(
            await fixture.synthesizer.requestedVoiceDescriptions.last
                == "Dramatic narrator"
        )
    }

    @Test("Playback startup failures are not reported as synthesis failures")
    func playbackStartupFailureClassification() async throws {
        let fixture = try ServiceFixture(synthesizesAudio: true)
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        fixture.playback.enqueueError = PlaybackError.couldNotStartEngine
        await fixture.service.start()

        let errorCode = try await terminalErrorCode(
            for: SpeechSubmission(
                text: "This reaches the playback device.",
                source: .commandLine,
                modelID: "kokoro-bf16",
                permitsLongText: true
            ),
            service: fixture.service
        )

        #expect(errorCode == "playback.failed")
    }

    @Test("Installed models validate and complete voice-studio workflows")
    func installedModelVoiceStudio() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: "kokoro-bf16")
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        await fixture.service.start()

        for (command, code) in [
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: "kokoro-bf16",
                        language: "en",
                        sampleText: "Sample"
                    )
                ),
                "voice.discovery_unsupported"
            ),
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: fixture.seedModelID,
                        language: "en",
                        sampleText: " ",
                        candidateCount: 1
                    )
                ),
                "voice.invalid_sample_text"
            ),
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: fixture.seedModelID,
                        language: "en",
                        sampleText: String(repeating: "x", count: 501),
                        candidateCount: 1
                    )
                ),
                "voice.invalid_sample_text"
            ),
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: fixture.seedModelID,
                        language: "en",
                        sampleText: "Sample",
                        candidateCount: 0
                    )
                ),
                "voice.invalid_candidate_count"
            ),
            (
                ServiceCommand.startVoiceClone(
                    VoiceCloneRequest(
                        recordingID: UUID(),
                        modelID: "kokoro-bf16",
                        language: "en",
                        transcript: "Transcript",
                        tuning: VoiceTuning()
                    )
                ),
                "voice.cloning_unsupported"
            ),
            (
                ServiceCommand.startVoiceClone(
                    VoiceCloneRequest(
                        recordingID: UUID(),
                        modelID: fixture.seedModelID,
                        language: "en",
                        transcript: " ",
                        tuning: VoiceTuning()
                    )
                ),
                "voice.transcript_required"
            ),
            (
                ServiceCommand.startVoiceClone(
                    VoiceCloneRequest(
                        recordingID: UUID(),
                        modelID: fixture.seedModelID,
                        language: "en",
                        transcript: String(repeating: "x", count: 1_001),
                        tuning: VoiceTuning()
                    )
                ),
                "voice.invalid_transcript"
            ),
            (
                ServiceCommand.startVoiceClone(
                    VoiceCloneRequest(
                        recordingID: UUID(),
                        modelID: fixture.seedModelID,
                        language: "en",
                        transcript: "Transcript",
                        tuning: VoiceTuning()
                    )
                ),
                "voice.recording_not_found"
            ),
            (
                ServiceCommand.startVoiceDiscovery(
                    VoiceDiscoveryRequest(
                        modelID: fixture.seedModelID,
                        language: "en",
                        sampleText: "Sample",
                        candidateCount: 2,
                        candidateTunings: [VoiceTuning()]
                    )
                ),
                "voice.invalid_candidate_count"
            )
        ] {
            #expect(
                try failure(
                    await fixture.service.handle(.init(command: command))
                ).code == code
            )
        }

        let discovery = try voiceStudio(
            await fixture.service.handle(
                .init(
                    command: .startVoiceDiscovery(
                        VoiceDiscoveryRequest(
                            modelID: fixture.seedModelID,
                            language: "de",
                            sampleText: "Eine kurze Probe.",
                            candidateCount: 1
                        )
                    )
                )
            )
        )
        #expect(discovery.state == .generating)
        try await waitForVoiceStudioState(.ready, service: fixture.service)
        let readyDiscovery = try #require(
            try snapshot(
                await fixture.service.handle(.init(command: .snapshot))
            ).voiceStudio
        )
        let discoveredCandidate = try #require(
            readyDiscovery.candidates.first
        )
        let discoveryPreview = try exportedFile(
            await fixture.service.handle(
                .init(command: .voicePreview(discoveredCandidate.id))
            )
        )
        #expect(discoveryPreview.contentType == "audio/wav")
        #expect(!discoveryPreview.data.isEmpty)

        let retuning = VoiceTuning(
            preset: .expressive,
            parameters: VoiceTuningSpace.defaults(
                modelType: "qwen3_tts",
                preset: .expressive
            )
        )
        let rerolledStudio = try voiceStudio(
            await fixture.service.handle(
                .init(
                    command: .regenerateVoiceCandidate(
                        discoveredCandidate.id,
                        tuning: retuning
                    )
                )
            )
        )
        let rerolledCandidate = try #require(
            rerolledStudio.candidates.first {
                $0.id == discoveredCandidate.id
            }
        )
        #expect(rerolledCandidate.tuning == retuning)
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .regenerateVoiceCandidate(
                            discoveredCandidate.id,
                            tuning: VoiceTuning(
                                parameters: ["temperature": 99]
                            )
                        )
                    )
                )
            ).code == "voice.invalid_tuning"
        )
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .regenerateVoiceCandidate(
                            UUID(),
                            tuning: retuning
                        )
                    )
                )
            ).code == "voice.preview_not_found"
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .saveVoiceCandidate(
                            discoveredCandidate.id,
                            name: "Copper Finch",
                            tuning: rerolledCandidate.tuning
                        )
                    )
                )
            )
        )

        let savedProfile = try #require(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: fixture.seedModelID))
                )
            ).first { $0.displayName == "Copper Finch" }
        )
        #expect(savedProfile.tuning == retuning)
        let profilePreview = try exportedFile(
            await fixture.service.handle(
                .init(
                    command: .previewVoiceProfile(
                        savedProfile.id,
                        tuning: retuning,
                        text: "A quick preview of this voice."
                    )
                )
            )
        )
        #expect(profilePreview.contentType == "audio/wav")
        #expect(!profilePreview.data.isEmpty)
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .previewVoiceProfile(
                            savedProfile.id,
                            tuning: retuning,
                            text: " "
                        )
                    )
                )
            ).code == "voice.invalid_sample_text"
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .updateVoiceTuning(
                            savedProfile.id,
                            VoiceTuning(
                                preset: .faithful,
                                parameters: VoiceTuningSpace.defaults(
                                    modelType: "qwen3_tts",
                                    preset: .faithful
                                )
                            )
                        )
                    )
                )
            )
        )
        #expect(
            try voices(
                await fixture.service.handle(
                    .init(command: .voices(modelID: fixture.seedModelID))
                )
            ).first { $0.id == savedProfile.id }?.tuning.preset == .faithful
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .duplicateVoiceProfile(
                            savedProfile.id,
                            name: "Copper Finch Duo",
                            tuning: retuning
                        )
                    )
                )
            )
        )
        let duplicated = try voices(
            await fixture.service.handle(
                .init(command: .voices(modelID: fixture.seedModelID))
            )
        )
        #expect(duplicated.count == 2)
        #expect(
            duplicated.first { $0.displayName == "Copper Finch Duo" }?.tuning
                == retuning
        )
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .updateVoiceTuning(
                            savedProfile.id,
                            VoiceTuning(parameters: ["temperature": 99])
                        )
                    )
                )
            ).code == "voice.invalid_tuning"
        )
        #expect(
            try failure(
                await fixture.service.handle(
                    .init(
                        command: .duplicateVoiceProfile(
                            savedProfile.id,
                            name: "copper finch",
                            tuning: retuning
                        )
                    )
                )
            ).code == "voice.duplicate_name"
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .cancelVoiceStudio)
                )
            )
        )

        let recordingID = UUID()
        try await fixture.seedRecording(id: recordingID, duration: 3.5)
        let clone = try voiceStudio(
            await fixture.service.handle(
                .init(
                    command: .startVoiceClone(
                        VoiceCloneRequest(
                            recordingID: recordingID,
                            modelID: fixture.seedModelID,
                            language: "de",
                            transcript: "Eine kurze Aufnahme.",
                            tuning: VoiceTuning()
                        )
                    )
                )
            )
        )
        #expect(clone.state == .generating)
        try await waitForVoiceStudioState(.ready, service: fixture.service)
        let readyClone = try #require(
            try snapshot(
                await fixture.service.handle(.init(command: .snapshot))
            ).voiceStudio
        )
        #expect(readyClone.candidates.count == 3)
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .saveVoiceClone(
                            readyClone.id,
                            name: "Recorded Harbor"
                        )
                    )
                )
            )
        )
        let savedVoices = try voices(
            await fixture.service.handle(.init(command: .voices(modelID: nil)))
        )
        #expect(
            Set(savedVoices.map(\.displayName))
                == ["Copper Finch", "Copper Finch Duo", "Recorded Harbor"]
        )
    }

    @Test("Chatterbox clones do not condition on or retain a transcript")
    func chatterboxCloneOmitsTranscript() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        let modelID = "chatterbox-fp16"
        try fixture.seedInstallation(modelID: modelID)
        await fixture.service.start()

        let recordingID = UUID()
        try await fixture.seedRecording(id: recordingID, duration: 8)
        let clone = try voiceStudio(
            await fixture.service.handle(
                .init(
                    command: .startVoiceClone(
                        VoiceCloneRequest(
                            recordingID: recordingID,
                            modelID: modelID,
                            language: "en",
                            transcript: "This text must not be retained.",
                            tuning: VoiceTuning()
                        )
                    )
                )
            )
        )
        #expect(clone.state == .generating)
        try await waitForVoiceStudioState(.ready, service: fixture.service)
        let referenceTranscripts = await fixture.synthesizer
            .referenceTranscripts
        #expect(referenceTranscripts.count == 3)
        #expect(referenceTranscripts.allSatisfy { $0 == nil })

        let ready = try #require(
            try snapshot(
                await fixture.service.handle(.init(command: .snapshot))
            ).voiceStudio
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .saveVoiceClone(
                            ready.id,
                            name: "Natural Harbor"
                        )
                    )
                )
            )
        )
        let store = VoiceProfileStore(directories: fixture.directories)
        let record = try #require(store.records(modelID: modelID).first)
        #expect(record.transcript == nil)
    }

    @Test("Uploaded local models integrate, select, and remove")
    func uploadedLocalModelLifecycle() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.remove() }
        try fixture.seedInstallation(modelID: fixture.seedModelID)
        let source = fixture.root.appending(
            path: "Upload",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: ["model_type": "qwen3_tts"]
        ).write(to: source.appending(path: "config.json"))
        try Data([1, 2, 3, 4]).write(
            to: source.appending(path: "model.safetensors")
        )

        try await fixture.service.importUploadedModel(from: source)
        await fixture.service.start()
        let imported = try #require(
            try models(
                await fixture.service.handle(.init(command: .models))
            ).first { $0.repository == "local-import" }
        )
        #expect(
            try snapshot(
                await fixture.service.handle(.init(command: .snapshot))
            ).installedModelIDs.contains(imported.id)
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .selectModel(imported.id))
                )
            )
        )
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(command: .removeModel(imported.id))
                )
            )
        )
        #expect(
            try models(
                await fixture.service.handle(.init(command: .models))
            ).contains { $0.id == imported.id } == false
        )
    }
}

@MainActor
private final class ServiceFixture {
    let root: URL
    let directories: AppDirectories
    let playback: RecordingBackendPlayback
    let synthesizer: DeterministicSynthesizer
    let service: SayItBackendService
    let seedModelID = "qwen3-06b-base-8bit"
    private(set) var profileID: UUID?
    private(set) var historyID: UUID?

    init(
        seedVoiceAndHistory: Bool = false,
        synthesizesAudio: Bool = false,
        synthesisEventGate: BackendSynthesisEventGate? = nil,
        downloadCatalog: ModelCatalog? = nil,
        downloadSession: URLSession? = nil,
        dependencyPreparationGate: DependencyPreparationGate? = nil,
        eventSleep: ServiceEventHub.Sleep? = nil,
        synthesisStallTimeout: Duration = .seconds(300)
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SayItServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        directories = try AppDirectories.testing(root: root)
        if seedVoiceAndHistory {
            profileID = UUID()
            try Self.seedProfile(
                id: profileID!,
                modelID: seedModelID,
                directories: directories
            )
            historyID = try Self.seedHistory(directories: directories)
        }
        playback = RecordingBackendPlayback()
        synthesizer = DeterministicSynthesizer(
            synthesizesAudio: synthesizesAudio,
            eventGate: synthesisEventGate,
            dependencyPreparationGate: dependencyPreparationGate
        )
        let modelManager: ModelManager?
        if let downloadCatalog {
            modelManager = ModelManager(
                catalog: downloadCatalog,
                directories: directories,
                activeModelID: ModelID("active"),
                session: downloadSession ?? .shared
            )
        } else {
            modelManager = nil
        }
        service = try SayItBackendService(
            directories: directories,
            serviceVersion: "test-version",
            playback: playback,
            synthesizer: synthesizer,
            catalogOverride: downloadCatalog,
            modelManagerOverride: modelManager,
            eventSleep: eventSleep,
            synthesisStallTimeout: synthesisStallTimeout
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func seedInstallation(modelID: String) throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let model = try #require(
            catalog.models.first {
                $0.id.rawValue == modelID
            }
        )
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
            to: directory.appending(path: "installation.json")
        )
    }

    func seedRecording(id: UUID, duration: Double) async throws {
        let directory = try VoiceProfileStore(
            directories: directories
        ).prepareDraftDirectory(id: id)
        let sampleRate = 24_000.0
        let samples = (0..<Int(sampleRate * duration)).map { frame in
            Float(
                sin(
                    2 * .pi * 180 * Double(frame) / sampleRate
                ) * 0.15
            )
        }
        let rawURL = directory.appending(path: "raw.wav")
        try await AudioArchive(directory: directories.voiceDrafts).writeWAV(
            samples: samples,
            sampleRate: sampleRate,
            destination: rawURL
        )
        _ = try VoiceRecordingProcessor().process(
            source: rawURL,
            destination: directory.appending(path: "reference.wav"),
            targetSampleRate: sampleRate,
            minimumDuration: 0,
            maximumDuration: 60
        )
    }

    private static func seedProfile(
        id: UUID,
        modelID: String,
        directories: AppDirectories
    ) throws {
        let directory = directories.voiceProfiles
            .appending(path: modelID)
            .appending(path: id.uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0x52, 0x49, 0x46, 0x46]).write(
            to: directory.appending(path: "reference.wav")
        )
        let now = Date()
        let record = VoiceProfileRecord(
            schemaVersion: 1,
            id: id,
            modelID: modelID,
            displayName: "Silver Lark",
            origin: .recordedClone,
            language: "en",
            transcript: "Private transcript",
            duration: 4,
            referenceFilename: "reference.wav",
            createdAt: now,
            updatedAt: now,
            sortOrder: 0,
            tuning: VoiceTuning(),
            generationSeed: nil
        )
        try JSONEncoder.sayIt.encode(record).write(
            to: directory.appending(path: "profile.json")
        )
    }

    private static func seedHistory(
        directories: AppDirectories
    ) throws -> UUID {
        let store = try HistoryStore(directories: directories)
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )
        let request = SpeechRequest(
            cleanedText: CleanedText(
                text: "Saved text",
                title: "Saved title",
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: model.defaultVoice,
            language: "en",
            source: .frontend
        )
        try store.begin(request)
        let relativePath = "\(request.id.uuidString).m4a"
        try Data([1, 2, 3]).write(
            to: directories.historyAudio.appending(path: relativePath)
        )
        try store.complete(
            id: request.id,
            duration: 2,
            audioRelativePath: relativePath,
            audioByteCount: 3
        )
        return request.id
    }
}

private actor BackendEventSleepRecorder {
    private var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}

private actor BackendEventSleepGate {
    private var isSleeping = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async throws {
        _ = duration
        isSleeping = true
        let waiters = startedWaiters
        startedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSleeping() async {
        guard !isSleeping else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor BackendSynthesisEventGate {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseNext() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }
        waiters.removeFirst().resume()
    }
}

private actor DeterministicSynthesizer: BackendSpeechSynthesizing {
    private(set) var requestedModelIDs: [String] = []
    private(set) var requestedLanguages: [String?] = []
    private(set) var requestedVoiceDescriptions: [String?] = []
    private(set) var referenceTranscripts: [String?] = []
    private(set) var unloadCount = 0
    private let synthesizesAudio: Bool
    private let eventGate: BackendSynthesisEventGate?
    private let dependencyPreparationGate: DependencyPreparationGate?

    init(
        synthesizesAudio: Bool = false,
        eventGate: BackendSynthesisEventGate? = nil,
        dependencyPreparationGate: DependencyPreparationGate? = nil
    ) {
        self.synthesizesAudio = synthesizesAudio
        self.eventGate = eventGate
        self.dependencyPreparationGate = dependencyPreparationGate
    }

    func synthesize(
        _ request: SpeechRequest
    ) async -> AsyncThrowingStream<SynthesisEvent, Error> {
        requestedModelIDs.append(request.model.id.rawValue)
        requestedLanguages.append(request.language)
        requestedVoiceDescriptions.append(request.voiceDescription)
        guard synthesizesAudio else {
            return AsyncThrowingStream { continuation in
                continuation.yield(.loadingModel(request.model.id))
                continuation.finish(
                    throwing: SynthesisError.modelNotInstalled
                )
            }
        }
        let chunks = TextChunker(
            targetCharacterCount: 2_000,
            hardCharacterLimit: 2_500
        ).chunks(for: request.cleanedText.text)
        if let eventGate, chunks.count >= 2 {
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.modelLoaded(request.model.id))
                    for (index, chunk) in chunks.prefix(2).enumerated() {
                        if index > 0 {
                            await eventGate.wait()
                        }
                        continuation.yield(
                            .chunkStarted(index: index, chunk: chunk)
                        )
                        continuation.yield(
                            .audio(
                                AudioChunk(
                                    requestID: request.id,
                                    index: index,
                                    samples: [0.1],
                                    sampleRate: 1,
                                    startsParagraph: chunk.startsParagraph
                                )
                            )
                        )
                    }
                    await eventGate.wait()
                    continuation.yield(.completed)
                    continuation.finish()
                }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.modelLoaded(request.model.id))
            for (index, chunk) in chunks.enumerated() {
                continuation.yield(
                    .chunkStarted(index: index, chunk: chunk)
                )
                continuation.yield(
                    .audio(
                        AudioChunk(
                            requestID: request.id,
                            index: index,
                            samples: [0.1],
                            sampleRate: 1,
                            startsParagraph: chunk.startsParagraph
                        )
                    )
                )
            }
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func cancelCurrentRequest() async {}

    func unloadModel() async {
        unloadCount += 1
    }

    func updateConfiguration(
        chunkTarget _: Int,
        chunkDelay _: Double,
        paragraphPause _: Double,
        idleUnloadDelay _: Double
    ) async {}

    func prepareDependencies(for _: ModelDescriptor) async throws {
        if let dependencyPreparationGate {
            await dependencyPreparationGate.wait()
        }
    }

    func generateVoiceSample(
        model _: ModelDescriptor,
        text _: String,
        language _: String?,
        tuning _: VoiceSynthesisTuning,
        seed _: UInt64,
        reference: VoiceReference?
    ) async throws -> GeneratedVoiceSample {
        referenceTranscripts.append(reference?.transcript)
        return GeneratedVoiceSample(
            samples: (0..<2_400).map { frame in
                Float(
                    sin(2 * .pi * 220 * Double(frame) / 24_000) * 0.1
                )
            },
            sampleRate: 24_000
        )
    }
}

@MainActor
private final class RecordingBackendPlayback: BackendPlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)?
    var onExternalControl: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (PlaybackState) -> Void)?
    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var currentModelID: String?
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var playedFileTitle: String?
    var enqueueError: Error?
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
    var volume: Double = 1
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    func prepare(
        requestID _: UUID,
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
        if let enqueueError {
            throw enqueueError
        }
        generatedDuration += chunk.duration
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
        playCount += 1
        state = .playing
    }

    func pause() {
        pauseCount += 1
        state = .paused
    }

    func stop() {
        stopCount += 1
        state = .idle
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        currentTitle = ""
        currentModelID = nil
    }

    func stopForModelSwitch() async {
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

    func finishForTesting() {
        state = .finished
    }

    func notifyExternalControl() {
        onExternalControl?()
    }

    func archive(
        using _: AudioArchive
    ) async throws -> AudioArchiveResult {
        throw ServiceFailure(
            code: "test.archive_unavailable",
            message: "Not used by these tests."
        )
    }

    func playFile(at _: URL, title: String, modelID: String?) throws {
        playedFileTitle = title
        currentTitle = title
        currentModelID = modelID
        state = .playing
    }
}

private func snapshot(_ response: ServiceResponse) throws -> ServiceSnapshot {
    guard case .snapshot(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func events(_ response: ServiceResponse) throws -> [ServiceEvent] {
    guard case .events(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func failure(_ response: ServiceResponse) throws -> ServiceFailure {
    guard case .failure(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func submittedJob(_ response: ServiceResponse) throws -> SpeechJob {
    guard case .job(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func jobList(_ response: ServiceResponse) throws -> [SpeechJob] {
    guard case .jobs(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func models(_ response: ServiceResponse) throws -> [ModelSnapshot] {
    guard case .models(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func voices(
    _ response: ServiceResponse
) throws -> [VoiceProfileSnapshot] {
    guard case .voices(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func history(_ response: ServiceResponse) throws -> [HistorySnapshot] {
    guard case .history(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func diagnosticList(
    _ response: ServiceResponse
) throws -> [DiagnosticSnapshot] {
    guard case .diagnostics(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func exportedFile(_ response: ServiceResponse) throws -> ExportedFile {
    guard case .file(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func voiceStudio(
    _ response: ServiceResponse
) throws -> VoiceStudioSnapshot {
    guard case .voiceStudio(let value) = response else {
        throw TestResponseError.unexpected
    }
    return value
}

private func isAccepted(_ response: ServiceResponse) -> Bool {
    if case .accepted = response { return true }
    return false
}

@MainActor
private func waitForJobState(
    _ state: SpeechJobState,
    id: UUID,
    service: SayItBackendService
) async throws {
    for _ in 0..<300 {
        let jobs = try jobList(
            await service.handle(.init(command: .jobs))
        )
        if jobs.first(where: { $0.id == id })?.state == state {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Job \(id) did not reach \(state.rawValue)")
}

@MainActor
private func waitForTerminalJob(
    _ id: UUID,
    service: SayItBackendService
) async throws {
    for _ in 0..<300 {
        let jobs = try jobList(
            await service.handle(.init(command: .jobs))
        )
        if jobs.first(where: { $0.id == id })?.state.isTerminal == true {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Job \(id) did not become terminal")
}

@MainActor
private func terminalErrorCode(
    for submission: SpeechSubmission,
    service: SayItBackendService
) async throws -> String? {
    let job = try submittedJob(
        await service.handle(.init(command: .submit(submission)))
    )
    try await waitForTerminalJob(job.id, service: service)
    return try jobList(
        await service.handle(.init(command: .jobs))
    ).first(where: { $0.id == job.id })?.errorCode
}

@MainActor
private func waitForVoiceStudioState(
    _ state: VoiceStudioState,
    service: SayItBackendService
) async throws {
    for _ in 0..<300 {
        let current = try snapshot(
            await service.handle(.init(command: .snapshot))
        ).voiceStudio
        if current?.state == state {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Voice studio did not reach \(state.rawValue)")
}

@MainActor
private func waitForServiceSnapshot(
    _ service: SayItBackendService,
    matching predicate: (ServiceSnapshot) -> Bool
) async throws -> ServiceSnapshot {
    for _ in 0..<400 {
        let current = try snapshot(
            await service.handle(.init(command: .snapshot))
        )
        if predicate(current) {
            return current
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestResponseError.timedOut
}

private actor DependencyPreparationGate {
    private(set) var hasEntered = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RestartableDownloadURLProtocol: URLProtocol,
    @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.withLock {
            handler = newHandler
        }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let result = Self.lock.withLock {
            Self.handler?(request)
        }
        guard let (response, data) = result else { return }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func downloadTestModel(
    config: Data,
    weights: Data
) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID("download-lifecycle"),
        displayName: "Download Lifecycle",
        family: "Tests",
        repository: "tests/download-lifecycle",
        revision: "revision",
        modelType: "qwen3_tts",
        parameterCount: "1",
        quantization: "none",
        languages: ["en"],
        voices: ["test-voice"],
        defaultVoice: "test-voice",
        defaultLanguage: "en",
        capabilities: ModelCapabilities(
            presetVoices: true,
            voiceDescription: false,
            voiceCloning: false,
            streaming: false,
            longForm: true,
            languageSelection: true,
            requiresReferenceAudio: false
        ),
        playbackMode: .buffered,
        files: [
            ModelFileDescriptor(
                path: "config.json",
                byteCount: Int64(config.count),
                sha256: downloadSHA256(config)
            ),
            ModelFileDescriptor(
                path: "model.safetensors",
                byteCount: Int64(weights.count),
                sha256: downloadSHA256(weights)
            )
        ],
        estimatedDiskBytes: Int64(config.count + weights.count),
        estimatedPeakMemoryBytes: 1,
        hardwareTier: .base,
        license: ModelLicense(
            identifier: "test",
            url: URL(string: "https://example.invalid")!,
            commercialUseAllowed: true,
            requiresAcceptance: false
        ),
        stability: .stable,
        testedMLXAudioVersion: "test",
        testedDate: "test"
    )
}

private func downloadSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
        String(byte, radix: 16).leftPadding(toLength: 2, withPad: "0")
    }.joined()
}

private enum TestResponseError: Error {
    case unexpected
    case timedOut
}
