import Foundation
import Testing
@testable import SayItBackend

@Suite("Audio route recovery policy")
struct AudioRouteRecoveryPolicyTests {
    @Test("Stable render anchors are finite and bounded")
    func stableAnchors() {
        #expect(
            AudioRouteRecoveryPolicy.stableAnchor(
                lastRendered: 12,
                fallback: 11.9,
                duration: 30
            ) == 12
        )
        #expect(
            AudioRouteRecoveryPolicy.stableAnchor(
                lastRendered: .nan,
                fallback: 4,
                duration: 30
            ) == 4
        )
        #expect(
            AudioRouteRecoveryPolicy.stableAnchor(
                lastRendered: 40,
                fallback: 39,
                duration: 30
            ) == 30
        )
    }

    @Test("Recovery uses bounded increasing backoff")
    func retryBackoff() {
        let delays = AudioRouteRecoveryPolicy.retryDelays

        #expect(delays.count == 4)
        #expect(delays.first == .zero)
        #expect(delays == delays.sorted())
        #expect(delays.last == .milliseconds(500))
    }

    @Test("Only transient output failures are retried")
    func retryableFailures() {
        #expect(
            AudioRouteRecoveryPolicy.canRetry(
                PlaybackError.noOutputDevice
            )
        )
        #expect(
            AudioRouteRecoveryPolicy.canRetry(
                PlaybackError.couldNotStartEngine
            )
        )
        #expect(
            !AudioRouteRecoveryPolicy.canRetry(
                PlaybackError.audioFormatMismatch
            )
        )
    }
}
