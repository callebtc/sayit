import Foundation
import SayItProtocol
import Testing

struct ProtocolRoundTripTests {
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
    func tokenPresetsNeverGrantWritesToReadOnlyClients() {
        #expect(!APITokenPreset.readOnly.scopes.contains(.speechSubmit))
        #expect(!APITokenPreset.readOnly.scopes.contains(.settingsWrite))
        #expect(APITokenPreset.fullAccess.scopes == Set(APITokenScope.allCases))
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
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let decoded = try SayItWireCodec.decode(
            ServiceSnapshot.self,
            from: legacyData
        )

        #expect(decoded.httpServiceError == nil)
    }
}
