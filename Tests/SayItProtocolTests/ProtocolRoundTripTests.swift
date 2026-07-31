import Foundation
import SayItProtocol
import Testing

struct ProtocolRoundTripTests {
    @Test
    func selectionServiceMessagesRoundTripThroughJSON() throws {
        let responses: [SelectionServiceResponse] = [
            .authorizationStatus(isTrusted: true),
            .selectedText("Selected text"),
            .authorizationRequired,
            .noSelection,
            .selectionTooLong(maximumCharacters: 1_000_000),
            .unavailable
        ]

        for response in responses {
            let decoded = try SayItWireCodec.decode(
                SelectionServiceResponse.self,
                from: SayItWireCodec.encode(response)
            )
            #expect(decoded == response)
        }

        let request = SelectionServiceRequest.selectedText
        let decodedRequest = try SayItWireCodec.decode(
            SelectionServiceRequest.self,
            from: SayItWireCodec.encode(request)
        )
        #expect(decodedRequest == request)
        #expect(SayItProtocolVersion.current == 6)
    }

    @Test
    func serviceRequestRoundTripsThroughJSON() throws {
        let request = ServiceRequest(
            command: .submit(
                SpeechSubmission(
                    text: "Hello from another process.",
                    source: .commandLine,
                    voice: "af_heart",
                    queuePolicy: .interruptCurrent
                )
            )
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ServiceRequest.self, from: data)

        #expect(decoded.id == request.id)
        guard case .submit(let submission) = decoded.command else {
            Issue.record("Expected a submission command")
            return
        }
        #expect(submission.text == "Hello from another process.")
        #expect(submission.queuePolicy == .interruptCurrent)
    }

    @Test
    func terminalJobStatesAreIdentified() {
        #expect(SpeechJobState.completed.isTerminal)
        #expect(SpeechJobState.canceled.isTerminal)
        #expect(SpeechJobState.failed.isTerminal)
        #expect(!SpeechJobState.playing.isTerminal)
    }

    @Test
    func eventRequestsRoundTripThroughJSON() throws {
        let request = ServiceRequest(command: .events(after: 42))
        let data = try SayItWireCodec.encode(request)
        let decoded = try SayItWireCodec.decode(
            ServiceRequest.self,
            from: data
        )
        guard case .events(let sequence) = decoded.command else {
            Issue.record("Expected an event request")
            return
        }
        #expect(sequence == 42)
    }

    @Test
    func diagnosticDetailsRoundTripThroughJSON() throws {
        let snapshot = DiagnosticSnapshot(
            id: UUID(),
            timestamp: .now,
            severity: "info",
            category: "model",
            code: "model.switch_completed",
            modelID: "kitten-mini-08",
            durationMilliseconds: 42,
            byteCount: 128,
            numericValue: 3.5
        )

        let decoded = try SayItWireCodec.decode(
            DiagnosticSnapshot.self,
            from: SayItWireCodec.encode(snapshot)
        )

        #expect(decoded.modelID == snapshot.modelID)
        #expect(decoded.durationMilliseconds == 42)
        #expect(decoded.byteCount == 128)
        #expect(decoded.numericValue == 3.5)
    }

    @Test
    func tokenPresetsNeverGrantWritesToReadOnlyClients() {
        #expect(!APITokenPreset.readOnly.scopes.contains(.speechSubmit))
        #expect(!APITokenPreset.readOnly.scopes.contains(.settingsWrite))
        #expect(APITokenPreset.readOnly.scopes.contains(.voicesRead))
        #expect(!APITokenPreset.readOnly.scopes.contains(.voicesWrite))
        #expect(APITokenPreset.fullAccess.scopes == Set(APITokenScope.allCases))
    }

    @Test
    func voiceSelectionsRoundTripThroughJSON() throws {
        let profileID = UUID()
        let selections: [VoiceSelection] = [
            .automaticStable,
            .preset("af_heart"),
            .profile(profileID),
            .randomPerParagraph
        ]

        for selection in selections {
            let encoded = try SayItWireCodec.encode(selection)
            let decoded = try SayItWireCodec.decode(
                VoiceSelection.self,
                from: encoded
            )
            #expect(decoded == selection)
        }
    }

    @Test
    func legacyVoiceMigratesToCurrentModelPreset() throws {
        let legacyJSON = """
        {
          "activeModelID": "kokoro-bf16",
          "activeVoice": "af_sky",
          "activeLanguage": "en-US",
          "voiceDescription": "",
          "speakingPace": 1,
          "playbackRate": 1,
          "rewindInterval": 15,
          "forwardInterval": 30,
          "showNowPlayingTitles": false,
          "retentionPeriod": "thirtyDays",
          "historyQuotaBytes": 2147483648,
          "httpEnabled": false,
          "httpPort": 59125
        }
        """

        let settings = try SayItWireCodec.decode(
            BackendSettingsSnapshot.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(settings.voiceSelections["kokoro-bf16"] == .preset("af_sky"))
    }

    @Test
    func speechSubmissionRetainsLegacyVoiceCompatibility() throws {
        let legacyJSON = """
        {
          "text": "Legacy request",
          "inputFormat": "plainText",
          "source": "commandLine",
          "voice": "af_heart",
          "queuePolicy": "enqueue",
          "permitsLongText": false
        }
        """

        let submission = try SayItWireCodec.decode(
            SpeechSubmission.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(submission.voice == "af_heart")
        #expect(submission.voiceSelection == nil)
    }

    @Test
    func voiceCloneCommandsRoundTripThroughProtocolV3() throws {
        let recordingID = UUID()
        let request = ServiceRequest(
            command: .startVoiceClone(
                VoiceCloneRequest(
                    recordingID: recordingID,
                    modelID: "omnivoice",
                    language: "en-US",
                    transcript: "A clear reference passage.",
                    tuning: VoiceTuning(
                        preset: .faithful,
                        parameters: ["guidance": 2.5]
                    )
                )
            )
        )

        let decoded = try SayItWireCodec.decode(
            ServiceRequest.self,
            from: SayItWireCodec.encode(request)
        )
        guard case .startVoiceClone(let clone) = decoded.command else {
            Issue.record("Expected a clone command")
            return
        }
        #expect(clone.recordingID == recordingID)
        #expect(clone.modelID == "omnivoice")
        #expect(clone.tuning.preset == .faithful)
        #expect(clone.tuning.parameters["guidance"] == 2.5)
    }

    @Test
    func cliVoiceProfileResolutionSupportsUUIDAndModelScopedNames() throws {
        let qwen = voiceProfile(name: "Silver Lark", modelID: "qwen")
        let omni = voiceProfile(name: "Silver Lark", modelID: "omni")
        let resolver = VoiceProfileResolver()

        #expect(
            try resolver.resolve(
                identifier: qwen.id.uuidString,
                requestedModelID: nil,
                currentModelID: "omni",
                profiles: [qwen, omni]
            ).id == qwen.id
        )
        #expect(
            try resolver.resolve(
                identifier: "silver lark",
                requestedModelID: "omni",
                currentModelID: "qwen",
                profiles: [qwen, omni]
            ).id == omni.id
        )
        #expect(throws: ServiceFailure.self) {
            _ = try resolver.resolve(
                identifier: qwen.id.uuidString,
                requestedModelID: "omni",
                currentModelID: "omni",
                profiles: [qwen, omni]
            )
        }
    }

    @Test
    func voiceReorderCommandRoundTripsThroughJSON() throws {
        let orderedIDs = [UUID(), UUID(), UUID()]
        let request = ServiceRequest(
            command: .reorderVoices(modelID: "qwen3_tts", orderedIDs: orderedIDs)
        )

        let decoded = try SayItWireCodec.decode(
            ServiceRequest.self,
            from: SayItWireCodec.encode(request)
        )
        guard case .reorderVoices(let modelID, let decodedIDs) = decoded.command
        else {
            Issue.record("Expected a reorder command")
            return
        }
        #expect(modelID == "qwen3_tts")
        #expect(decodedIDs == orderedIDs)
    }

    private func voiceProfile(
        name: String,
        modelID: String
    ) -> VoiceProfileSnapshot {
        VoiceProfileSnapshot(
            id: UUID(),
            modelID: modelID,
            displayName: name,
            origin: .generated,
            language: "en-US",
            duration: 7,
            createdAt: .now,
            updatedAt: .now,
            tuning: VoiceTuning()
        )
    }

    @Test
    func localHTTPFailuresRoundTripSeparatelyFromGlobalErrors() throws {
        let snapshot = ServiceSnapshot(
            serviceVersion: "1.0",
            revision: 1,
            statusText: "Ready to speak",
            lastError: nil,
            httpServiceError: "The local API could not start.",
            activeJob: nil,
            queuedJobs: [],
            playback: PlaybackSnapshot(),
            download: nil,
            installedModelIDs: [],
            settings: BackendSettingsSnapshot(),
            modelsRevision: 0,
            historyRevision: 0,
            diagnosticsRevision: 0
        )

        let data = try SayItWireCodec.encode(snapshot)
        let decoded = try SayItWireCodec.decode(
            ServiceSnapshot.self,
            from: data
        )

        #expect(decoded.lastError == nil)
        #expect(decoded.httpServiceError == "The local API could not start.")
    }

    @Test
    func serviceSnapshotDecodesWithoutLocalHTTPFailureField() throws {
        let snapshot = ServiceSnapshot(
            serviceVersion: "1.0",
            revision: 1,
            statusText: "Ready to speak",
            lastError: nil,
            activeJob: nil,
            queuedJobs: [],
            playback: PlaybackSnapshot(),
            download: nil,
            installedModelIDs: [],
            settings: BackendSettingsSnapshot(),
            modelsRevision: 0,
            historyRevision: 0,
            diagnosticsRevision: 0
        )
        let encoded = try SayItWireCodec.encode(snapshot)
        var legacyJSON = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON["httpServiceError"] = nil
        legacyJSON["voicesRevision"] = nil
        legacyJSON["voiceStudio"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let decoded = try SayItWireCodec.decode(
            ServiceSnapshot.self,
            from: legacyData
        )

        #expect(decoded.httpServiceError == nil)
        #expect(decoded.voicesRevision == 0)
        #expect(decoded.voiceStudio == nil)
    }

    @Test
    func playbackSnapshotContentMetadataIsBackwardCompatible() throws {
        let snapshot = PlaybackSnapshot(
            state: "playing",
            elapsed: 2,
            generatedDuration: 5,
            estimatedDuration: 5,
            spokenText: "Hello"
        )
        let encoded = try SayItWireCodec.encode(snapshot)
        var legacyJSON = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON["includesContent"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let decoded = try SayItWireCodec.decode(
            PlaybackSnapshot.self,
            from: legacyData
        )

        #expect(decoded.includesContent)
        #expect(decoded.spokenText == "Hello")
    }
}
