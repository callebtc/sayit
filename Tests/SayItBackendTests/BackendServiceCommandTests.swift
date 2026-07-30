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
            ).last?.snapshot.revision == started.revision
        )

        let mismatch = await fixture.service.handle(
            .init(protocolVersion: -1, command: .snapshot)
        )
        #expect(
            try failure(mismatch).code == "protocol.version_mismatch"
        )

        await fixture.service.reportServiceError("Transport failed")
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
        #expect(fixture.playback.backwardSkipInterval == 7)
        #expect(fixture.playback.forwardSkipInterval == 42)
        #expect(fixture.playback.showTitleInNowPlaying)
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
                            text: "Queued behind long content",
                            source: .http
                        )
                    )
                )
            )
        )
        let queuedSnapshot = try snapshot(
            await fixture.service.handle(.init(command: .snapshot))
        )
        #expect(queuedSnapshot.activeJob?.id == long.id)
        #expect(queuedSnapshot.queuedJobs.map(\.id) == [queued.id])

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
                ServiceCommand.saveVoiceCandidate(UUID(), name: "Name"),
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
        #expect(
            isAccepted(
                await fixture.service.handle(
                    .init(
                        command: .saveVoiceCandidate(
                            discoveredCandidate.id,
                            name: "Copper Finch"
                        )
                    )
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
                == ["Copper Finch", "Recorded Harbor"]
        )
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

    init(seedVoiceAndHistory: Bool = false) throws {
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
        synthesizer = DeterministicSynthesizer()
        service = try SayItBackendService(
            directories: directories,
            serviceVersion: "test-version",
            playback: playback,
            synthesizer: synthesizer
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func seedInstallation(modelID: String) throws {
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
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
        try await AudioArchive(directory: directories.voiceDrafts).writeWAV(
            samples: samples,
            sampleRate: sampleRate,
            destination: directory.appending(path: "reference.wav")
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

private actor DeterministicSynthesizer: BackendSpeechSynthesizing {
    private(set) var requestedModelIDs: [String] = []
    private(set) var unloadCount = 0

    func synthesize(
        _ request: SpeechRequest
    ) async -> AsyncThrowingStream<SynthesisEvent, Error> {
        requestedModelIDs.append(request.model.id.rawValue)
        return AsyncThrowingStream { continuation in
            continuation.yield(.loadingModel(request.model.id))
            continuation.finish(throwing: SynthesisError.modelNotInstalled)
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

    func prepareDependencies(for _: ModelDescriptor) async throws {}

    func generateVoiceSample(
        model _: ModelDescriptor,
        text _: String,
        language _: String?,
        tuning _: VoiceSynthesisTuning,
        seed _: UInt64,
        reference _: VoiceReference?
    ) async throws -> GeneratedVoiceSample {
        GeneratedVoiceSample(
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
    private(set) var state: PlaybackState = .idle
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
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
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

private enum TestResponseError: Error {
    case unexpected
}
