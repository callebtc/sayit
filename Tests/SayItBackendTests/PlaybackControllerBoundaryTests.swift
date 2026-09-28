import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Playback controller calculations")
struct PlaybackControllerBoundaryTests {
    @Test("Pausing preparation holds arriving audio and completion until resumed")
    @MainActor
    func pausesBeforeFirstAudio() throws {
        let playback = PlaybackController()
        let id = UUID()
        playback.prepare(requestID: id, title: "Test", estimatedDuration: 10, modelID: nil)
        playback.pause()
        #expect(playback.state == .paused)
        try playback.enqueue(AudioChunk(
            requestID: id, index: 0,
            samples: [Float](repeating: 0.1, count: 2_400),
            sampleRate: 24_000, startsParagraph: true
        ))
        #expect(playback.state == .paused)
        #expect(!playback.shouldStartWhenBuffered)
        playback.finishBuffering()
        #expect(playback.state == .paused)
        playback.stop()
    }

    @Test("Resuming before audio exists rearms automatic buffered playback")
    @MainActor
    func resumesBeforeFirstAudio() {
        let playback = PlaybackController()
        playback.prepare(requestID: UUID(), title: "Test", estimatedDuration: 10, modelID: nil)
        playback.pause()
        playback.play()
        #expect(playback.state == .buffering)
        #expect(!playback.shouldStartWhenBuffered)
        playback.stop()
    }

    @Test("Playback buffer duration grows only above normal speed")
    @MainActor
    func preferredBufferDuration() {
        #expect(PlaybackController.preferredStartBufferDuration(for: -1) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 0.5) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 1) == 1.2)
        #expect(
            abs(
                PlaybackController.preferredStartBufferDuration(for: 1.5)
                    - 1.8
            ) < 0.000_001
        )
    }

    @Test("Playback timeline is single-instance and restartable")
    @MainActor
    func playbackTimelineLifecycle() async {
        let sleeper = TimelineSleepGate()
        let ticks = TimelineTickCounter()
        let timeline = PlaybackController.TimelineDriver { duration in
            try await sleeper.sleep(for: duration)
        }

        #expect(
            PlaybackController.TimelineDriver.interval
                == .milliseconds(250)
        )
        #expect(!timeline.isActive)

        timeline.start(onTick: ticks.record)
        timeline.start(onTick: ticks.record)
        #expect(timeline.isActive)
        await waitForRequests(1, from: sleeper)
        #expect(await sleeper.durations() == [.milliseconds(250)])
        #expect(await sleeper.pendingCount() == 1)

        await sleeper.resumeNext()
        await waitForRequests(2, from: sleeper)
        #expect(ticks.count == 1)
        #expect(timeline.isActive)

        timeline.stop()
        #expect(!timeline.isActive)
        timeline.start(onTick: ticks.record)
        #expect(timeline.isActive)
        await waitForRequests(3, from: sleeper)
        await waitForPendingCount(1, from: sleeper)

        await sleeper.resumeNext()
        await waitForRequests(4, from: sleeper)
        #expect(ticks.count == 2)
        #expect(timeline.isActive)

        timeline.stop()
        await waitForPendingCount(0, from: sleeper)
        #expect(!timeline.isActive)
        #expect(
            await sleeper.durations()
                == Array(repeating: .milliseconds(250), count: 4)
        )
    }

    @Test("Playback timeline clears failed cadence and can restart")
    @MainActor
    func playbackTimelineRecoversFromClockFailure() async {
        let sleeper = TimelineSleepGate()
        let timeline = PlaybackController.TimelineDriver { duration in
            try await sleeper.sleep(for: duration)
        }

        timeline.start {}
        await waitForRequests(1, from: sleeper)
        await sleeper.failNext()
        while timeline.isActive {
            await Task.yield()
        }

        timeline.start {}
        await waitForRequests(2, from: sleeper)
        #expect(timeline.isActive)

        timeline.stop()
        await waitForPendingCount(0, from: sleeper)
    }

    @Test("Playback timeline cancels its cadence on deinitialization")
    @MainActor
    func playbackTimelineDeinitialization() async {
        let sleeper = TimelineSleepGate()
        var timeline: PlaybackController.TimelineDriver? =
            PlaybackController.TimelineDriver { duration in
                try await sleeper.sleep(for: duration)
            }
        weak let weakTimeline = timeline

        timeline?.start {}
        await waitForRequests(1, from: sleeper)
        timeline = nil

        #expect(weakTimeline == nil)
        await waitForPendingCount(0, from: sleeper)
    }

    @MainActor
    private func waitForRequests(
        _ count: Int,
        from sleeper: TimelineSleepGate
    ) async {
        while await sleeper.requestCount() < count {
            await Task.yield()
        }
    }

    @MainActor
    private func waitForPendingCount(
        _ count: Int,
        from sleeper: TimelineSleepGate
    ) async {
        while await sleeper.pendingCount() != count {
            await Task.yield()
        }
    }
}

@MainActor
private final class TimelineTickCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor TimelineSleepGate {
    private var nextID = 0
    private var requestedDurations: [Duration] = []
    private var waiterOrder: [Int] = []
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requestedDurations.append(duration)
                waiterOrder.append(id)
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(id)
            }
        }
    }

    func requestCount() -> Int {
        requestedDurations.count
    }

    func durations() -> [Duration] {
        requestedDurations
    }

    func pendingCount() -> Int {
        waiters.count
    }

    func resumeNext() {
        takeNext()?.resume()
    }

    func failNext() {
        takeNext()?.resume(throwing: TimelineSleepFailure())
    }

    private func cancel(_ id: Int) {
        waiterOrder.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func takeNext() -> CheckedContinuation<Void, Error>? {
        guard !waiterOrder.isEmpty else { return nil }
        let id = waiterOrder.removeFirst()
        return waiters.removeValue(forKey: id)
    }
}

private struct TimelineSleepFailure: Error {}
