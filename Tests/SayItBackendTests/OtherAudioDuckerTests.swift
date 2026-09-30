import Foundation
import SayItCore
import Synchronization
import Testing
@testable import SayItBackend

@Suite("Other audio ducker")
@MainActor
struct OtherAudioDuckerTests {
    @Test("Only audible speech states lower other audio")
    func duckingStates() {
        let ducked = [PlaybackState.playing, .buffering]
        let restored = [PlaybackState.idle, .preparing, .paused, .finished, .failed]

        #expect(ducked.allSatisfy(OtherAudioDucker.shouldDuck(during:)))
        #expect(!restored.contains(where: OtherAudioDucker.shouldDuck(during:)))
    }

    @Test("Disabled ducker never touches other audio")
    func disabledDoesNothing() {
        let harness = Harness()
        harness.ducker.isEnabled = false

        harness.ducker.playbackStateDidChange(.playing)

        #expect(harness.routers.isEmpty)
    }

    @Test("Speech lowers other audio to the configured level")
    func ducksToLevel() throws {
        let harness = Harness(level: 0.3)

        harness.ducker.playbackStateDidChange(.playing)

        let router = try #require(harness.routers.first)
        #expect(router.gains == [
            GainChange(gain: 0.3, ramp: OtherAudioDucker.duckRampDuration),
        ])
        #expect(harness.ducker.isDucking)
    }

    @Test("Other audio is restored and released after speech ends")
    func restoresAfterSpeech() async throws {
        let harness = Harness()
        harness.ducker.playbackStateDidChange(.playing)
        let router = try #require(harness.routers.first)

        harness.ducker.playbackStateDidChange(.finished)
        #expect(!router.isStopped)
        await harness.clock.advance()
        await harness.clock.advance()

        #expect(router.gains.last == GainChange(
            gain: 1,
            ramp: OtherAudioDucker.restoreRampDuration
        ))
        #expect(router.isStopped)
        #expect(!harness.ducker.isDucking)
    }

    @Test("Speech that resumes during the hold keeps the same route")
    func resumingSpeechCancelsRestore() async throws {
        let harness = Harness()
        harness.ducker.playbackStateDidChange(.playing)
        harness.ducker.playbackStateDidChange(.finished)

        harness.ducker.playbackStateDidChange(.playing)
        await harness.clock.advance()
        await harness.clock.advance()

        let router = try #require(harness.routers.first)
        #expect(harness.routers.count == 1)
        #expect(!router.isStopped)
        #expect(!router.gains.contains { $0.gain == 1 })
        #expect(harness.ducker.isDucking)
    }

    @Test("Turning the setting off restores other audio immediately")
    func disablingStopsRoute() throws {
        let harness = Harness()
        harness.ducker.playbackStateDidChange(.playing)

        harness.ducker.isEnabled = false

        #expect(try #require(harness.routers.first).isStopped)
    }

    @Test("Level changes apply while speech is playing")
    func levelChangeWhileDucking() throws {
        let harness = Harness()
        harness.ducker.playbackStateDidChange(.playing)

        harness.ducker.level = 0

        #expect(try #require(harness.routers.first).gains.last == GainChange(
            gain: 0,
            ramp: OtherAudioDucker.duckRampDuration
        ))
    }

    @Test("Output device changes rebuild the route")
    func outputDeviceChangeRebuilds() throws {
        let harness = Harness()
        harness.ducker.playbackStateDidChange(.playing)
        let first = try #require(harness.routers.first)

        first.onOutputDeviceChange?()

        #expect(first.isStopped)
        #expect(harness.routers.count == 2)
        #expect(harness.ducker.isDucking)
    }

    @Test("Route failures are reported once until a route starts")
    func failureReportedOnce() {
        let harness = Harness(failing: true)

        harness.ducker.playbackStateDidChange(.playing)
        harness.ducker.playbackStateDidChange(.finished)
        harness.ducker.playbackStateDidChange(.playing)

        #expect(harness.failures.count == 1)
        #expect(!harness.ducker.isDucking)
    }
}

private struct GainChange: Equatable {
    let gain: Float
    let ramp: TimeInterval
}

@MainActor
private final class FakeRouter: OtherAudioRouting {
    var onOutputDeviceChange: (@MainActor () -> Void)?
    private(set) var gains: [GainChange] = []
    private(set) var isStopped = false

    func setGain(_ gain: Float, rampDuration: TimeInterval) {
        gains.append(GainChange(gain: gain, ramp: rampDuration))
    }

    func stop() {
        isStopped = true
    }
}

private struct RouteUnavailable: Error {}

/// A sleep whose waiters resume only when the test advances the clock.
private final class ManualClock: Sendable {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            waiters.withLock { $0.append(continuation) }
        }
        try Task.checkCancellation()
    }

    @MainActor
    func advance() async {
        // Let a freshly scheduled task reach its sleep before resuming it.
        for _ in 0..<5 { await Task.yield() }
        let pending = waiters.withLock { waiters in
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class Harness {
    let clock = ManualClock()
    private(set) var routers: [FakeRouter] = []
    private(set) var failures: [any Error] = []
    private(set) var ducker: OtherAudioDucker!

    init(level: Double = 0.2, failing: Bool = false) {
        let clock = clock
        ducker = OtherAudioDucker(
            makeRouter: { [unowned self] in
                if failing { throw RouteUnavailable() }
                let router = FakeRouter()
                routers.append(router)
                return router
            },
            sleep: { try await clock.sleep($0) }
        )
        ducker.onFailure = { [unowned self] in failures.append($0) }
        ducker.level = level
        ducker.isEnabled = true
    }
}
