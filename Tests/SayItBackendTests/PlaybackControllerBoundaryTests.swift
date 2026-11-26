import Foundation
import Testing
import SayItCore
import SayItProtocol
@testable import SayItBackend

@Suite("Playback controller calculations")
struct PlaybackControllerBoundaryTests {
    @Test("Streaming startup uses delivered audio and resets across requests")
    @MainActor
    func streamingProgressLifecycle() throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        let requestID = UUID()
        playback.setPlaybackMode(.adaptive)
        playback.prepare(requestID: requestID, title: "Stream", estimatedDuration: 100, modelID: "stream-test")
        try playback.enqueue(AudioChunk(requestID: requestID, index: 0,
            samples: Array(repeating: 0, count: 32_000), sampleRate: 8000, startsParagraph: false))
        #expect(!playback.shouldStartWhenBuffered)
        let progress = SynthesisProgress(chunkIndex: 0, generatedAudioDuration: 4,
            generationDuration: 1.6, recentRealTimeFactor: 0.4, deliveredAudioPieces: 6,
            maximumDeliveryGap: 0.6)
        playback.observeSynthesisProgress(progress)
        #expect(playback.shouldStartWhenBuffered)
        playback.stop()
        playback.observeSynthesisProgress(progress)
        #expect(!playback.shouldStartWhenBuffered)
        playback.prepare(requestID: UUID(), title: "Next", estimatedDuration: 100, modelID: "stream-test")
        #expect(!playback.shouldStartWhenBuffered)
    }

    @Test("Audio graph reuses matching sample rate across stops and reconfigures on sample-rate or route change")
    @MainActor
    func audioGraphReusesAndSwitchesSampleRate() throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0

        let steps: [(sampleRate: Double, expectedConfigCount: Int)] = [
            (24_000.0, 1),
            (24_000.0, 1),
            (44_100.0, 2),
            (24_000.0, 3)
        ]

        for step in steps {
            let requestID = UUID()
            playback.prepare(
                requestID: requestID,
                title: "Rate \(Int(step.sampleRate))",
                estimatedDuration: 0.5,
                modelID: "rate-test"
            )
            let samples = [Float](repeating: 0.01, count: Int(step.sampleRate * 0.1))
            try playback.enqueue(AudioChunk(
                requestID: requestID,
                index: 0,
                samples: samples,
                sampleRate: step.sampleRate,
                startsParagraph: false
            ))
            #expect(playback.audioGraphConfigurationCount == step.expectedConfigCount)
            #expect(playback.state == .buffering)
            #expect(abs(playback.generatedDuration - 0.1) < 0.001)
            playback.stop()
            #expect(playback.state == .idle)
        }

        // An output-route change while idle must invalidate the cached sample
        // rate so the next utterance reconfigures the graph for the new device.
        playback.handleAudioConfigurationChangeForTesting()
        let postRouteID = UUID()
        playback.prepare(
            requestID: postRouteID,
            title: "Post-route change",
            estimatedDuration: 0.5,
            modelID: "rate-test"
        )
        try playback.enqueue(AudioChunk(
            requestID: postRouteID,
            index: 0,
            samples: [Float](repeating: 0.01, count: 2_400),
            sampleRate: 24_000,
            startsParagraph: false
        ))
        #expect(playback.audioGraphConfigurationCount == 4)

        // A route change while audio is buffered must not stop the player on a
        // subsequent progressive enqueue during the debounce window, and must
        // still rebuild the graph if stop() cancels the debounced recovery task.
        playback.handleAudioConfigurationChangeForTesting()
        try playback.enqueue(AudioChunk(
            requestID: postRouteID,
            index: 1,
            samples: [Float](repeating: 0.01, count: 2_400),
            sampleRate: 24_000,
            startsParagraph: false
        ))
        // Graph stays untouched during debounce so already-scheduled buffers are preserved.
        #expect(playback.audioGraphConfigurationCount == 4)
        #expect(abs(playback.generatedDuration - 0.2) < 0.001)
        playback.stop()

        let postBufferedRouteID = UUID()
        playback.prepare(
            requestID: postBufferedRouteID,
            title: "Post-buffered-route change",
            estimatedDuration: 0.5,
            modelID: "rate-test"
        )
        try playback.enqueue(AudioChunk(
            requestID: postBufferedRouteID,
            index: 0,
            samples: [Float](repeating: 0.01, count: 2_400),
            sampleRate: 24_000,
            startsParagraph: false
        ))
        #expect(playback.audioGraphConfigurationCount == 5)

        // Calling play() during a pending route-change debounce must rebuild
        // the graph and reschedule cleanly rather than discarding queued frames.
        playback.handleAudioConfigurationChangeForTesting()
        playback.play()
        #expect(playback.audioGraphConfigurationCount == 6)
        #expect(playback.state == .playing)
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
