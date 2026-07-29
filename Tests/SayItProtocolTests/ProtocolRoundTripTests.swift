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
}
