import Foundation
import PlaybackDSP
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Playback controller behavior")
@MainActor
struct PlaybackControllerTests {
    @Test("Buffering policies control start readiness across modes and metrics")
    func bufferingPolicies() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.setPlaybackMode(.progressive)
        controller.prepare(
            requestID: id,
            title: "Progressive",
            estimatedDuration: 10,
            modelID: "model-a"
        )
        #expect(abs(controller.preferredStartBufferDuration - 1.2) < 0.000_001)
        try fixture.enqueue(requestID: id, duration: 1.1)
        #expect(!controller.shouldStartWhenBuffered)
        try fixture.enqueue(requestID: id, duration: 0.2, index: 1)
        #expect(controller.shouldStartWhenBuffered)

        controller.setPlaybackMode(.buffered)
        #expect(abs(controller.preferredStartBufferDuration - 2.5) < 0.000_001)
        #expect(!controller.shouldStartWhenBuffered)
        try fixture.enqueue(requestID: id, duration: 1.3, index: 2)
        #expect(controller.shouldStartWhenBuffered)

        controller.setPlaybackMode(.completeFirst)
        #expect(controller.preferredStartBufferDuration == .infinity)
        #expect(!controller.shouldStartWhenBuffered)
        controller.finishBuffering()
        #expect(controller.state == .playing)
        #expect(!controller.shouldStartWhenBuffered)
    }

    @Test("Adaptive and metric-driven buffering ignores invalid observations")
    func adaptiveAndMetricDrivenBuffering() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller

        let unmeasuredID = UUID()
        controller.setPlaybackMode(.adaptive)
        controller.prepare(
            requestID: unmeasuredID,
            title: "Adaptive",
            estimatedDuration: 20,
            modelID: "adaptive-fast"
        )
        try fixture.enqueue(requestID: unmeasuredID, duration: 5)
        #expect(!controller.shouldStartWhenBuffered)

        // Invalid and non-finite metrics must not influence readiness.
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: .nan,
                audioDuration: 1
            )
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 1,
                generationDuration: .infinity,
                audioDuration: 1
            )
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 2,
                generationDuration: -1,
                audioDuration: 1
            )
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 3,
                generationDuration: 1,
                audioDuration: 0
            )
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 4,
                generationDuration: 1,
                audioDuration: .infinity
            )
        )
        #expect(!controller.shouldStartWhenBuffered)

        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 5,
                generationDuration: 1,
                audioDuration: 4
            )
        )
        #expect(controller.shouldStartWhenBuffered)

        // Slow adaptive model requires enough lead to outlast remaining generation.
        let slowID = UUID()
        controller.prepare(
            requestID: slowID,
            title: "Adaptive Slow",
            estimatedDuration: 11.4,
            modelID: "adaptive-slow"
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 8,
                audioDuration: 4
            )
        )
        // At 5.4s buffered and 6.0s remaining, adjustedLoad=2.0 -> need 6.4s.
        try fixture.enqueue(requestID: slowID, duration: 5.4)
        #expect(!controller.shouldStartWhenBuffered)
        // At 6.4s buffered and 5.0s remaining, need (2.0-1)*5.0 + 0.4 = 5.4s.
        try fixture.enqueue(requestID: slowID, duration: 1.0, index: 1)
        #expect(controller.shouldStartWhenBuffered)

        // Progressive rate-adjusted sustainability: rtf=0.6 is sustainable at 1x, not at 2x.
        let rateID = UUID()
        controller.setPlaybackMode(.progressive)
        controller.prepare(
            requestID: rateID,
            title: "Rate Sustainability",
            estimatedDuration: 10,
            modelID: "medium-model"
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 6,
                audioDuration: 10
            )
        )
        try fixture.enqueue(requestID: rateID, duration: 0.2)
        #expect(controller.shouldStartWhenBuffered)
        controller.rate = 2
        #expect(!controller.shouldStartWhenBuffered)
        controller.finishBuffering()
        #expect(controller.state == .playing)
    }

    @Test("Rolling metrics window bounds history and keeps percentile lead")
    func boundedPerformanceEstimator() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.setPlaybackMode(.progressive)
        controller.prepare(
            requestID: id,
            title: "Rolling",
            estimatedDuration: 30,
            modelID: "rolling-model"
        )
        for index in 0..<20 {
            controller.observeSynthesisMetrics(
                SynthesisMetrics(
                    chunkIndex: index,
                    generationDuration: Double(index),
                    audioDuration: 100
                )
            )
        }
        // Last 12 observations are 8...19; 90th percentile index ceil(0.9*12)-1 = 10 -> 18.
        // preferredStartBufferDuration = (18 + 0.4) * 1 = 18.4.
        #expect(abs(controller.preferredStartBufferDuration - 18.4) < 0.000_001)

        // Metrics observed without an active modelID are ignored.
        controller.prepare(
            requestID: UUID(),
            title: "No Model",
            estimatedDuration: 10,
            modelID: nil
        )
        controller.observeSynthesisMetrics(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 9.5,
                audioDuration: 10
            )
        )
        #expect(abs(controller.preferredStartBufferDuration - 1.2) < 0.000_001)
    }

    @Test(
        "Sonic time stretching preserves output duration and flushes tail across rates",
        arguments: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    )
    func sonicTimeStretchingAcrossRates(rate: Double) throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0
        let inputSamples = fixture.makeTone(sampleRate: sampleRate, duration: 1.0)

        controller.rate = rate
        controller.prepare(
            requestID: id,
            title: "Sonic \(rate)x",
            estimatedDuration: 1.0,
            modelID: nil
        )
        try controller.enqueue(
            AudioChunk(
                requestID: id,
                index: 0,
                samples: inputSamples,
                sampleRate: sampleRate,
                startsParagraph: false
            )
        )
        controller.finishBuffering()

        #expect(controller.state == .playing)
        let scheduled = fixture.audioOutput.allScheduledSamples
        let expectedFrames = Int((Double(inputSamples.count) / rate).rounded())
        #expect(scheduled.count == expectedFrames)
        #expect(scheduled.allSatisfy { $0.isFinite })
        if rate == 1.0 {
            #expect(scheduled == inputSamples)
        }

        fixture.audioOutput.completeAllBuffers()
        #expect(controller.state == .finished)
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)
        #expect(controller.failureMessage == nil)
    }

    @Test("Live mid-playback speed changes, pause/seek, and replay preserve position")
    func midPlaybackSpeedChangesAndReplay() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.rate = 0.5
        controller.prepare(
            requestID: id,
            title: "Speed Controls",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0, sampleRate: sampleRate)
        controller.finishBuffering()
        #expect(controller.state == .playing)

        // At 0.5x, 14_400 output frames = 0.6s output = 0.3s source audio.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 14_400,
            sampleRate: sampleRate
        )
        let scheduledBeforeSwitch = fixture.audioOutput.scheduledBuffers.count
        controller.rate = 2.0

        #expect(controller.state == .playing)
        #expect(abs(controller.elapsed - 0.3) < 0.000_001)
        #expect(fixture.audioOutput.stopPlayerCount >= 1)
        let switchedBuffers = Array(
            fixture.audioOutput.scheduledBuffers.dropFirst(scheduledBeforeSwitch)
        )
        let switchedSamples = switchedBuffers.flatMap(\.samples)
        let expectedRemaining = Int((1.7 * sampleRate / 2.0).rounded())
        #expect(switchedSamples.count == expectedRemaining)
        #expect(switchedSamples.first == 0)

        controller.pause()
        #expect(controller.state == .paused)
        controller.rate = 0.75
        #expect(controller.state == .paused)

        controller.seek(to: 1.5)
        #expect(abs(controller.elapsed - 1.5) < 0.000_001)
        controller.play()
        #expect(controller.state == .playing)
        fixture.audioOutput.completeAllBuffers()
        #expect(controller.state == .finished)

        // Replay from finished applies the current rate from t=0.
        controller.rate = 2.0
        let countBeforeReplay = fixture.audioOutput.scheduledBuffers.count
        controller.play()
        #expect(controller.state == .playing)
        #expect(abs(controller.elapsed - 0) < 0.000_001)
        let replaySamples = fixture.audioOutput.scheduledBuffers
            .dropFirst(countBeforeReplay)
            .flatMap(\.samples)
        #expect(replaySamples.count == Int((2.0 * sampleRate / 2.0).rounded()))
        fixture.audioOutput.completeAllBuffers()
        #expect(controller.state == .finished)
    }

    @Test("Horizon caps initial scheduling at 12s, refills 2s on completion, and resets on seek")
    func horizonCappingRefillAndSeekReset() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.prepare(
            requestID: id,
            title: "Long",
            estimatedDuration: 15.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 15.0, sampleRate: sampleRate)
        controller.finishBuffering()

        #expect(controller.state == .playing)
        #expect(fixture.audioOutput.activeBuffers.count == 6)
        #expect(fixture.audioOutput.totalScheduledSampleCount == 12 * 24_000)

        let staleCompletion = fixture.audioOutput.activeBuffers.first?.completion

        // Completing one 2s segment opens room for one 2s refill.
        #expect(fixture.audioOutput.completeNextBuffer())
        #expect(fixture.audioOutput.activeBuffers.count == 6)
        #expect(fixture.audioOutput.totalScheduledSampleCount == 14 * 24_000)

        // Completing one more segment schedules the remaining 1s tail.
        #expect(fixture.audioOutput.completeNextBuffer())
        #expect(fixture.audioOutput.activeBuffers.count == 6)
        #expect(fixture.audioOutput.totalScheduledSampleCount == 15 * 24_000)

        // Seeking resets the frame horizon and ignores stale pre-seek completions.
        let scheduledBeforeSeek = fixture.audioOutput.scheduledBuffers.count
        controller.seek(to: 1.0)
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)
        #expect(fixture.audioOutput.activeBuffers.count == 6)
        let seekScheduledCount = fixture.audioOutput.scheduledBuffers
            .dropFirst(scheduledBeforeSeek)
            .reduce(0) { $0 + $1.samples.count }
        #expect(seekScheduledCount == 12 * 24_000)

        staleCompletion?()
        #expect(fixture.audioOutput.activeBuffers.count == 6)
        #expect(fixture.audioOutput.scheduledBuffers.count == scheduledBeforeSeek + 6)
    }

    @Test("Progressive underrun transitions to buffering and automatically recovers on completion")
    func progressiveUnderrunAndRecovery() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.rate = 1.5
        controller.prepare(
            requestID: id,
            title: "Progressive Underrun",
            estimatedDuration: 1.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 0.5, sampleRate: sampleRate)
        controller.play()
        #expect(controller.state == .playing)

        let firstOutputFrames = Int64(fixture.audioOutput.totalScheduledSampleCount)
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: firstOutputFrames,
            sampleRate: sampleRate
        )
        fixture.audioOutput.completeAllBuffers()

        #expect(controller.state == .buffering)
        #expect(controller.elapsed < controller.generatedDuration)
        #expect(!fixture.audioOutput.isPlaying)

        try fixture.enqueue(
            requestID: id,
            duration: 0.5,
            sampleRate: sampleRate,
            index: 1
        )
        #expect(controller.state == .buffering)

        controller.finishBuffering()
        #expect(controller.state == .playing)
        fixture.audioOutput.completeAllBuffers()
        #expect(controller.state == .finished)
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)
    }

    @Test(
        "Smooth stops fade requested durations and clamp short tails",
        arguments: [
            (false, Duration.milliseconds(12), 288),
            (true, Duration.milliseconds(24), 576)
        ]
    )
    func smoothStopFades(
        forModelSwitch: Bool,
        expectedDuration: Duration,
        expectedFrames: Int
    ) async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.prepare(
            requestID: id,
            title: "Fade",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0)
        controller.finishBuffering()
        #expect(controller.state == .playing)

        let stopTask = Task {
            if forModelSwitch {
                await controller.stopForModelSwitch()
            } else {
                await controller.stopSmoothly()
            }
        }
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(expectedDuration)
        }

        #expect(controller.state == .paused)
        let fadeBuffer = try #require(fixture.audioOutput.scheduledBuffers.last)
        #expect(fadeBuffer.samples.count == expectedFrames)
        #expect(fadeBuffer.samples.last == 0)

        await fixture.advance(by: expectedDuration)
        await stopTask.value

        #expect(controller.state == .idle)
        #expect(fixture.mediaSession.clearNowPlayingCount >= 1)
        #expect(fixture.audioOutput.pauseEngineCount >= 1)
    }

    @Test("Smooth stop clamps fade sleep to remaining tail frames")
    func smoothStopShortTailClamping() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.prepare(
            requestID: id,
            title: "Short Tail",
            estimatedDuration: 0.05,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 0.05, sampleRate: sampleRate)
        controller.finishBuffering()
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 1_080,
            sampleRate: sampleRate
        )

        let stopTask = Task {
            await controller.stopForModelSwitch()
        }
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.seconds(0.005))
        }

        let fadeBuffer = try #require(fixture.audioOutput.scheduledBuffers.last)
        #expect(fadeBuffer.samples.count == 120)
        #expect(fadeBuffer.samples.last == 0)

        await fixture.advance(by: .milliseconds(5))
        await stopTask.value
        #expect(controller.state == .idle)
    }

    @Test("Smooth stop cleans up on cancellation and preserves superseding requests")
    func smoothStopCancellationAndSuperseding() async throws {
        let cancelFixture = PlaybackControllerFixture()
        let firstID = UUID()
        cancelFixture.controller.prepare(
            requestID: firstID,
            title: "Cancel Fade",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try cancelFixture.enqueue(requestID: firstID, duration: 2.0)
        cancelFixture.controller.finishBuffering()

        let cancelTask = Task {
            await cancelFixture.controller.stopSmoothly()
        }
        await cancelFixture.until {
            cancelFixture.clock.pendingSleepDurations.contains(.milliseconds(12))
        }
        cancelTask.cancel()
        await cancelTask.value
        #expect(cancelFixture.controller.state == .idle)
        #expect(cancelFixture.mediaSession.clearNowPlayingCount >= 1)
        #expect(cancelFixture.audioOutput.pauseEngineCount >= 1)

        // Superseding prepare prevents the older fade wakeup from stopping the new item.
        let supersedeFixture = PlaybackControllerFixture()
        let oldID = UUID()
        supersedeFixture.controller.prepare(
            requestID: oldID,
            title: "Old",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try supersedeFixture.enqueue(requestID: oldID, duration: 2.0)
        supersedeFixture.controller.finishBuffering()

        let oldStop = Task {
            await supersedeFixture.controller.stopSmoothly()
        }
        await supersedeFixture.until {
            supersedeFixture.clock.pendingSleepDurations.contains(.milliseconds(12))
        }

        let nextID = UUID()
        supersedeFixture.controller.prepare(
            requestID: nextID,
            title: "Next",
            estimatedDuration: 1.0,
            modelID: nil
        )
        try supersedeFixture.enqueue(requestID: nextID, duration: 1.0)
        await supersedeFixture.advance(by: .milliseconds(12))
        await oldStop.value

        #expect(supersedeFixture.controller.state == .buffering)
        #expect(supersedeFixture.controller.currentTitle == "Next")
    }

    @Test("Completion watchdog re-arms on partial progress and forces completion on stalled callbacks")
    func completionWatchdogRearmingAndForcedCompletion() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.prepare(
            requestID: id,
            title: "Watchdog",
            estimatedDuration: 1.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 1.0, sampleRate: sampleRate)
        controller.finishBuffering()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.seconds(1.75))
        }

        // Watchdog wakes with partial progress and re-arms for remaining 0.4s + 0.75s.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 14_400,
            sampleRate: sampleRate
        )
        await fixture.advance(by: .seconds(1.75))
        #expect(controller.state == .playing)
        #expect(abs(controller.elapsed - 0.6) < 0.000_001)
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains { abs(durationSeconds($0) - 1.15) < 0.001 }
        }

        // Audio finishes rendering, but buffer completion callback stalls -> watchdog completes playback.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 24_000,
            sampleRate: sampleRate
        )
        let stopCountBefore = fixture.audioOutput.stopPlayerCount
        await fixture.advance(by: .seconds(1.15))

        #expect(controller.state == .finished)
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)
        #expect(fixture.audioOutput.stopPlayerCount > stopCountBefore)
    }

    @Test("Timeline cadence is single-instance, tolerates sleep failures, and cleans up on deinit")
    func timelineCadenceAndDeinitializationCleanup() async throws {
        let fixture = PlaybackControllerFixture()
        let id = UUID()
        let sampleRate = 24_000.0

        fixture.controller.prepare(
            requestID: id,
            title: "Timeline",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0, sampleRate: sampleRate)
        fixture.controller.play()
        await fixture.until {
            fixture.clock.pendingSleepDurations == [.milliseconds(250)]
        }

        // Calling play() while already playing does not duplicate the timeline task.
        fixture.controller.play()
        await fixture.settle()
        #expect(fixture.clock.pendingSleepDurations == [.milliseconds(250)])

        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 6_000,
            sampleRate: sampleRate
        )
        await fixture.advance(by: .milliseconds(250))
        #expect(abs(fixture.controller.elapsed - 0.25) < 0.000_001)

        // Clock errors stop the cadence without failing playback, and pause/play restarts it.
        #expect(fixture.clock.failEarliestSleep(with: TestClockFailure()))
        await fixture.settle()
        #expect(fixture.controller.state == .playing)
        #expect(fixture.failures.isEmpty)
        #expect(fixture.clock.pendingSleepCount == 0)

        fixture.controller.pause()
        fixture.controller.play()
        await fixture.until {
            fixture.clock.pendingSleepDurations == [.milliseconds(250)]
        }

        // Deinitializing an active controller cancels its timeline and watchdog sleeps.
        let (weakBox, deinitClock) = try await makeDeinitializedController()
        for _ in 0..<200 {
            if weakBox.controller == nil && deinitClock.pendingSleepCount == 0 {
                break
            }
            await Task.yield()
        }
        #expect(weakBox.controller == nil)
        #expect(deinitClock.pendingSleepCount == 0)
    }

    @Test("Now Playing throttles timeline ticks at 500ms and respects title privacy")
    func nowPlayingThrottlingAndTitlePrivacy() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()
        let sampleRate = 24_000.0

        controller.prepare(
            requestID: id,
            title: "Secret Article",
            estimatedDuration: 5.0,
            modelID: nil
        )
        #expect(fixture.mediaSession.publishedInfos.last?.title == "Say It")

        controller.showTitleInNowPlaying = true
        #expect(fixture.mediaSession.publishedInfos.last?.title == "Secret Article")

        controller.showTitleInNowPlaying = false
        #expect(fixture.mediaSession.publishedInfos.last?.title == "Say It")

        try fixture.enqueue(requestID: id, duration: 5.0, sampleRate: sampleRate)
        controller.finishBuffering()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(250))
        }
        let publishedBeforeTicks = fixture.mediaSession.publishedInfos.count

        // +250ms tick is throttled.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 6_000,
            sampleRate: sampleRate
        )
        await fixture.advance(by: .milliseconds(250))
        #expect(fixture.mediaSession.publishedInfos.count == publishedBeforeTicks)

        // +500ms tick publishes updated elapsed.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 12_000,
            sampleRate: sampleRate
        )
        await fixture.advance(by: .milliseconds(250))
        #expect(fixture.mediaSession.publishedInfos.count == publishedBeforeTicks + 1)
        #expect(
            abs((fixture.mediaSession.publishedInfos.last?.elapsed ?? 0) - 0.5)
                < 0.000_001
        )

        // +750ms tick is throttled again.
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 18_000,
            sampleRate: sampleRate
        )
        await fixture.advance(by: .milliseconds(250))
        #expect(fixture.mediaSession.publishedInfos.count == publishedBeforeTicks + 1)

        // State transitions bypass throttling immediately.
        controller.pause()
        #expect(fixture.mediaSession.publishedInfos.count == publishedBeforeTicks + 2)
        #expect(fixture.mediaSession.publishedInfos.last?.playbackRate == 0)
    }

    @Test("Remote commands handle every command variant, custom skip intervals, and rate validation")
    func remoteCommandVariants() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        #expect(fixture.mediaSession.supportedPlaybackRates == PlaybackRate.presets)
        #expect(fixture.mediaSession.backwardSkipInterval == 15)
        #expect(fixture.mediaSession.forwardSkipInterval == 30)

        controller.backwardSkipInterval = 10
        controller.forwardSkipInterval = 25
        #expect(fixture.mediaSession.backwardSkipInterval == 10)
        #expect(fixture.mediaSession.forwardSkipInterval == 25)

        controller.prepare(
            requestID: id,
            title: "Remote",
            estimatedDuration: 80.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 80.0, sampleRate: 8_000)
        controller.finishBuffering()
        #expect(controller.state == .playing)

        fixture.mediaSession.sendRemoteCommand(.pause)
        #expect(controller.state == .paused)
        #expect(fixture.externalControlCount == 1)

        fixture.mediaSession.sendRemoteCommand(.play)
        #expect(controller.state == .playing)
        #expect(fixture.externalControlCount == 2)

        fixture.mediaSession.sendRemoteCommand(.togglePlayPause)
        #expect(controller.state == .paused)
        fixture.mediaSession.sendRemoteCommand(.togglePlayPause)
        #expect(controller.state == .playing)
        #expect(fixture.externalControlCount == 4)

        fixture.mediaSession.sendRemoteCommand(.seek(20.0))
        #expect(abs(controller.elapsed - 20.0) < 0.000_001)

        fixture.mediaSession.sendRemoteCommand(.nextTrack)
        #expect(abs(controller.elapsed - 45.0) < 0.000_001)

        fixture.mediaSession.sendRemoteCommand(.previousTrack)
        #expect(abs(controller.elapsed - 35.0) < 0.000_001)

        fixture.mediaSession.sendRemoteCommand(.skipForward)
        #expect(abs(controller.elapsed - 60.0) < 0.000_001)

        fixture.mediaSession.sendRemoteCommand(.skipBackward)
        #expect(abs(controller.elapsed - 50.0) < 0.000_001)
        #expect(fixture.externalControlCount == 9)

        fixture.mediaSession.sendRemoteCommand(.changePlaybackRate(1.53))
        #expect(controller.rate == 1.55)
        #expect(fixture.externalControlCount == 10)

        // Unsupported playback rates are ignored without firing external control.
        fixture.mediaSession.sendRemoteCommand(.changePlaybackRate(3.0))
        fixture.mediaSession.sendRemoteCommand(.changePlaybackRate(.nan))
        #expect(controller.rate == 1.55)
        #expect(fixture.externalControlCount == 10)

        fixture.mediaSession.sendRemoteCommand(.stop)
        #expect(controller.state == .idle)
        #expect(fixture.externalControlCount == 11)
        #expect(fixture.mediaSession.clearNowPlayingCount >= 1)
    }

    @Test("Route changes debounce rapid events and ignore idle or finished states")
    func routeRecoveryDebounceAndGuards() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller

        // Ignored while idle.
        fixture.audioOutput.emitConfigurationChange()
        await fixture.settle()
        #expect(fixture.clock.sleepDurations.isEmpty)

        let id = UUID()
        controller.prepare(
            requestID: id,
            title: "Debounce",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0)
        controller.finishBuffering()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(250))
        }
        fixture.audioOutput.renderedSamplePosition = PlaybackRenderPosition(
            frame: 24_000,
            sampleRate: 24_000
        )
        await fixture.advance(by: .milliseconds(250))
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)

        let graphsBeforeDebounce = fixture.audioOutput.configuredSampleRates.count

        // Three rapid route changes coalesce to one 150ms debounce from the final event.
        fixture.audioOutput.emitConfigurationChange()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(150))
        }
        await fixture.advance(by: .milliseconds(50))
        fixture.audioOutput.emitConfigurationChange()
        await fixture.settle()
        await fixture.advance(by: .milliseconds(50))
        fixture.audioOutput.emitConfigurationChange()
        await fixture.settle()

        await fixture.advance(by: .milliseconds(100))
        #expect(fixture.audioOutput.configuredSampleRates.count == graphsBeforeDebounce)

        await fixture.advance(by: .milliseconds(50))
        #expect(fixture.audioOutput.configuredSampleRates.count == graphsBeforeDebounce + 1)
        #expect(controller.state == .playing)
        #expect(abs(controller.elapsed - 1.0) < 0.000_001)

        // Ignored once playback has finished.
        fixture.audioOutput.completeAllBuffers()
        #expect(controller.state == .finished)
        let sleepsBeforeFinishedChange = fixture.clock.sleepDurations.count
        fixture.audioOutput.emitConfigurationChange()
        await fixture.settle()
        #expect(fixture.clock.sleepDurations.count == sleepsBeforeFinishedChange)

        // Paused playback recovers back into paused without auto-starting.
        let pausedID = UUID()
        controller.prepare(
            requestID: pausedID,
            title: "Paused Recovery",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: pausedID, duration: 2.0)
        controller.finishBuffering()
        controller.seek(to: 0.75)
        controller.pause()
        let graphsBeforePausedRecovery = fixture.audioOutput.configuredSampleRates.count
        fixture.audioOutput.emitConfigurationChange()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(150))
        }
        await fixture.advance(by: .milliseconds(150))
        #expect(
            fixture.audioOutput.configuredSampleRates.count
                == graphsBeforePausedRecovery + 1
        )
        #expect(controller.state == .paused)
        #expect(abs(controller.elapsed - 0.75) < 0.000_001)
    }

    @Test("Route recovery retries transient failures with 0/100/250/500ms backoff")
    func routeRecoveryTransientRetries() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.prepare(
            requestID: id,
            title: "Retry",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0)
        controller.finishBuffering()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(250))
        }

        // First three attempts fail with transient output errors; fourth succeeds.
        fixture.audioOutput.configureGraphOutcomes = [
            .failure(PlaybackError.noOutputDevice),
            .failure(PlaybackError.noOutputDevice),
            .failure(PlaybackError.couldNotStartEngine),
            .success(())
        ]
        fixture.audioOutput.emitConfigurationChange()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(150))
        }

        await fixture.advance(by: .milliseconds(150))
        #expect(fixture.clock.pendingSleepDurations.contains(.milliseconds(100)))
        await fixture.advance(by: .milliseconds(100))
        #expect(fixture.clock.pendingSleepDurations.contains(.milliseconds(250)))
        await fixture.advance(by: .milliseconds(250))
        #expect(fixture.clock.pendingSleepDurations.contains(.milliseconds(500)))
        await fixture.advance(by: .milliseconds(500))

        #expect(controller.state == .playing)
        #expect(fixture.failures.isEmpty)

        // Exhausting all retries transitions to failed.
        fixture.audioOutput.configureGraphOutcomes = [
            .failure(PlaybackError.noOutputDevice),
            .failure(PlaybackError.noOutputDevice),
            .failure(PlaybackError.noOutputDevice),
            .failure(PlaybackError.couldNotStartEngine)
        ]
        fixture.audioOutput.emitConfigurationChange()
        for delay in [
            Duration.milliseconds(150),
            .milliseconds(100),
            .milliseconds(250),
            .milliseconds(500)
        ] {
            await fixture.until {
                fixture.clock.pendingSleepDurations.contains(delay)
            }
            await fixture.advance(by: delay)
        }

        #expect(controller.state == .failed)
        #expect(fixture.failures.count == 1)
    }

    @Test("Route recovery fails immediately on non-retryable format mismatch")
    func routeRecoveryFormatMismatchFailsImmediately() async throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.prepare(
            requestID: id,
            title: "Mismatch",
            estimatedDuration: 2.0,
            modelID: nil
        )
        try fixture.enqueue(requestID: id, duration: 2.0)
        controller.finishBuffering()
        controller.pause()
        await fixture.settle()

        let sleepsBefore = fixture.clock.sleepDurations.count
        fixture.audioOutput.configureGraphOutcomes = [
            .failure(PlaybackError.audioFormatMismatch)
        ]
        fixture.audioOutput.emitConfigurationChange()
        await fixture.until {
            fixture.clock.pendingSleepDurations.contains(.milliseconds(150))
        }
        await fixture.advance(by: .milliseconds(150))

        #expect(controller.state == .failed)
        #expect(fixture.failures.count == 1)
        let recoverySleeps = Array(fixture.clock.sleepDurations.dropFirst(sleepsBefore))
        #expect(recoverySleeps == [.milliseconds(150)])
    }

    @Test("User controls cancel pending route recovery")
    func routeRecoveryCancelledByUserControls() async throws {
        for control in RecoveryCancellingControl.allCases {
            let fixture = PlaybackControllerFixture()
            let controller = fixture.controller
            let id = UUID()

            controller.prepare(
                requestID: id,
                title: "Cancel Recovery",
                estimatedDuration: 2.0,
                modelID: nil
            )
            try fixture.enqueue(requestID: id, duration: 2.0)
            controller.finishBuffering()

            fixture.audioOutput.configureGraphOutcomes = [
                .failure(PlaybackError.audioFormatMismatch)
            ]
            fixture.audioOutput.emitConfigurationChange()
            await fixture.until {
                fixture.clock.pendingSleepDurations.contains(.milliseconds(150))
            }
            let graphsBeforeControl = fixture.audioOutput.configuredSampleRates.count

            switch control {
            case .pause:
                controller.pause()
            case .seek:
                controller.seek(to: 0.5)
            case .stop:
                controller.stop()
            case .smoothStop:
                let task = Task { await controller.stopSmoothly() }
                await fixture.until {
                    fixture.clock.pendingSleepDurations.contains(.milliseconds(12))
                }
                await fixture.advance(by: .milliseconds(12))
                await task.value
            }

            await fixture.settle()
            #expect(
                fixture.clock.cancelledSleepDurations.contains(.milliseconds(150))
            )
            await fixture.advance(by: .milliseconds(200))
            #expect(controller.state != .failed)
            #expect(fixture.failures.isEmpty)
            #expect(fixture.audioOutput.configuredSampleRates.count == graphsBeforeControl)
        }
    }

    @Test("Enqueue validation, buffer scheduling rollback, and engine start failures surface errors cleanly")
    func enqueueAndPlaybackFailurePaths() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let activeID = UUID()

        controller.prepare(
            requestID: activeID,
            title: "Failures",
            estimatedDuration: 1.0,
            modelID: nil
        )
        #expect(fixture.stateChanges.last == .preparing)

        // Mismatched request chunks are ignored without side effects.
        try fixture.enqueue(requestID: UUID(), duration: 0.5)
        #expect(controller.generatedDuration == 0)
        #expect(controller.state == .preparing)

        // Empty samples and invalid sample rates fail before storing audio.
        #expect(throws: PlaybackError.emptyAudio) {
            try controller.enqueue(
                AudioChunk(
                    requestID: activeID,
                    index: 0,
                    samples: [],
                    sampleRate: 24_000,
                    startsParagraph: false
                )
            )
        }
        #expect(throws: PlaybackError.invalidSampleRate) {
            try controller.enqueue(
                AudioChunk(
                    requestID: activeID,
                    index: 0,
                    samples: [0.1, 0.2],
                    sampleRate: 0,
                    startsParagraph: false
                )
            )
        }

        // Inconsistent sample rate on subsequent chunk is rejected.
        try fixture.enqueue(requestID: activeID, duration: 0.5, sampleRate: 24_000)
        #expect(throws: PlaybackError.inconsistentSampleRate) {
            try fixture.enqueue(
                requestID: activeID,
                duration: 0.5,
                sampleRate: 44_100,
                index: 1
            )
        }

        // Scheduling failure rolls back scheduled counts and transitions cleanly to failed on play().
        fixture.audioOutput.scheduleBufferError = PlaybackError.audioFormatMismatch
        controller.seek(to: 0.1)
        #expect(controller.state == .failed)
        #expect(
            controller.failureMessage
                == PlaybackError.audioFormatMismatch.errorDescription
        )
        #expect(fixture.failures.count == 1)
        #expect(fixture.audioOutput.activeBuffers.isEmpty)

        // Recovering via play() after clearing scheduleBufferError still detects engine-start failure.
        fixture.audioOutput.scheduleBufferError = nil
        fixture.audioOutput.ensureEngineRunningOutcomes = [
            .success(()),
            .failure(PlaybackError.couldNotStartEngine)
        ]
        controller.play()
        #expect(controller.state == .failed)
        #expect(
            controller.failureMessage
                == PlaybackError.couldNotStartEngine.errorDescription
        )
        #expect(fixture.failures.count == 2)
        #expect(fixture.stateChanges.last == .failed)

        // A subsequent play() succeeds once the engine starts cleanly.
        controller.play()
        #expect(controller.state == .playing)
        #expect(controller.failureMessage == nil)
    }

    @Test("File replay rejects unsupported files without discarding prior playback and reads chunks")
    func fileReplayAndUnsupportedRejection() throws {
        let fixture = PlaybackControllerFixture()
        let controller = fixture.controller
        let id = UUID()

        controller.prepare(
            requestID: id,
            title: "Active Speech",
            estimatedDuration: 1.0,
            modelID: "model-1"
        )
        try fixture.enqueue(requestID: id, duration: 1.0)
        controller.finishBuffering()
        #expect(controller.state == .playing)

        // Unsupported or unreadable file throws before touching active playback.
        let badURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).m4a")
        #expect(throws: PlaybackError.unsupportedAudioFile) {
            try controller.playFile(at: badURL, title: "Bad", modelID: nil)
        }
        #expect(controller.state == .playing)
        #expect(controller.currentTitle == "Active Speech")
        #expect(controller.currentModelID == "model-1")
        #expect(abs(controller.generatedDuration - 1.0) < 0.000_001)
        #expect(!controller.amplitudes.isEmpty)

        // Valid multi-chunk file replaces active playback and streams chunked samples.
        let goodURL = URL(fileURLWithPath: "/tmp/valid-\(UUID().uuidString).m4a")
        let chunkA = fixture.makeTone(duration: 0.5)
        let chunkB = fixture.makeTone(duration: 0.5)
        fixture.audioOutput.fileOpeners[goodURL] = {
            ScriptedPlaybackAudioFile(
                sampleRate: 24_000,
                chunks: [chunkA, chunkB]
            )
        }
        try controller.playFile(at: goodURL, title: "History Item", modelID: "model-2")
        #expect(controller.state == .playing)
        #expect(controller.currentTitle == "History Item")
        #expect(controller.currentModelID == "model-2")
        #expect(abs(controller.generatedDuration - 1.0) < 0.000_001)

        // Mid-stream decode failure cleans up to idle and rethrows.
        let corruptURL = URL(fileURLWithPath: "/tmp/corrupt-\(UUID().uuidString).m4a")
        fixture.audioOutput.fileOpeners[corruptURL] = {
            ScriptedPlaybackAudioFile(
                sampleRate: 24_000,
                chunks: [chunkA, chunkB],
                chunkReadFailure: (index: 1, error: PlaybackError.unsupportedAudioFile)
            )
        }
        #expect(throws: PlaybackError.unsupportedAudioFile) {
            try controller.playFile(at: corruptURL, title: "Corrupt", modelID: nil)
        }
        #expect(controller.state == .idle)
    }
}

private enum RecoveryCancellingControl: CaseIterable {
    case pause
    case seek
    case stop
    case smoothStop
}

private struct TestClockFailure: Error {}

@MainActor
private final class WeakControllerBox {
    weak var controller: PlaybackController?
}

@MainActor
private func makeDeinitializedController() async throws -> (
    WeakControllerBox,
    VirtualPlaybackClock
) {
    let audioOutput = ScriptedPlaybackAudioOutput()
    let mediaSession = ScriptedPlaybackMediaSession()
    let clock = VirtualPlaybackClock()
    let box = WeakControllerBox()
    var controller: PlaybackController? = PlaybackController(
        audioOutput: audioOutput,
        mediaSession: mediaSession,
        clock: clock
    )
    box.controller = controller
    let id = UUID()
    let samples = (0..<24_000).map { frame in
        Float(0.1 * sin(2 * .pi * 220 * Double(frame) / 24_000))
    }
    controller?.prepare(
        requestID: id,
        title: "Deinit",
        estimatedDuration: 1.0,
        modelID: nil
    )
    try controller?.enqueue(
        AudioChunk(
            requestID: id,
            index: 0,
            samples: samples,
            sampleRate: 24_000,
            startsParagraph: false
        )
    )
    controller?.finishBuffering()
    for _ in 0..<500 {
        if clock.pendingSleepDurations.contains(.milliseconds(250))
            && clock.pendingSleepDurations.contains(.seconds(1.75)) {
            break
        }
        await Task.yield()
    }
    controller = nil
    _ = controller
    return (box, clock)
}

private func durationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
