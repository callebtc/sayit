import SayItCore
import SayItProtocol
import Testing
@testable import SayIt

@Suite("Selected-text permission recovery")
@MainActor
struct SelectionRequestFlowTests {
    @Test("Granting Accessibility resumes the original selection request")
    func resumesAfterAuthorization() async throws {
        var events: [String] = []
        var readAttempts = 0

        let payload = try await SelectionRequestFlow.perform(
            readSelection: {
                events.append("read")
                readAttempts += 1
                if readAttempts == 1 {
                    throw SelectionServiceError.accessibilityRequired
                }
                return TextSourcePayload(
                    source: .selection,
                    plainText: "Selected text"
                )
            },
            requestAuthorization: {
                events.append("authorize")
                return true
            },
            resumeTargetApplication: {
                events.append("resume")
            }
        )

        #expect(payload.plainText == "Selected text")
        #expect(events == ["read", "authorize", "resume", "read"])
    }

    @Test("Denied Accessibility does not retry against the wrong app")
    func doesNotRetryWhenAuthorizationIsDenied() async {
        var events: [String] = []

        do {
            _ = try await SelectionRequestFlow.perform(
                readSelection: {
                    events.append("read")
                    throw SelectionServiceError.accessibilityRequired
                },
                requestAuthorization: {
                    events.append("authorize")
                    return false
                },
                resumeTargetApplication: {
                    events.append("resume")
                }
            )
            Issue.record("Expected Accessibility to remain required")
        } catch SelectionServiceError.accessibilityRequired {
            #expect(events == ["read", "authorize"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Selection failures do not open Accessibility recovery")
    func preservesOrdinarySelectionFailures() async {
        var requestedAuthorization = false

        do {
            _ = try await SelectionRequestFlow.perform(
                readSelection: {
                    throw SelectionServiceError.noSelection
                },
                requestAuthorization: {
                    requestedAuthorization = true
                    return true
                },
                resumeTargetApplication: {}
            )
            Issue.record("Expected the missing selection error")
        } catch SelectionServiceError.noSelection {
            #expect(!requestedAuthorization)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
