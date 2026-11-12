import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Playback buffer policy")
struct PlaybackBufferPolicyTests {
    @Test("Paid prefill does not delay streaming until the full first chunk")
    func prefillAlreadyBuffered() {
        let streaming = PlaybackBufferPolicy(mode: .adaptive, rate: 1.2,
            estimator: SynthesisPerformanceEstimator())
        // Captured Q4 trace: 2.14s first delivery, then sustained faster output.
        let progress = SynthesisProgress(chunkIndex: 0, generatedAudioDuration: 6.679,
            generationDuration: 6.416, recentRealTimeFactor: 0.6004,
            deliveredAudioPieces: 8, maximumDeliveryGap: 2.137,
            initialGenerationDuration: 2.137, initialAudioDuration: 0.735)
        #expect(streaming.shouldStartStreaming(progress, bufferedDuration: 6.679))
        #expect(!streaming.shouldStartStreaming(progress, bufferedDuration: 5))
        let notDelivered = SynthesisProgress(chunkIndex: 0, generatedAudioDuration: 6.679,
            generationDuration: 6.416, recentRealTimeFactor: 0.6004,
            deliveredAudioPieces: 8, maximumDeliveryGap: 2.137,
            initialGenerationDuration: 6.416, initialAudioDuration: 6.679)
        #expect(!streaming.shouldStartStreaming(notDelivered, bufferedDuration: 100))
    }

    @Test("Delivered streaming pieces qualify startup without a complete text chunk")
    func deliveredStreamingStartup() {
        let estimator = SynthesisPerformanceEstimator()
        let streaming = PlaybackBufferPolicy(mode: .adaptive, rate: 1.2, estimator: estimator)
        func progress(audio: Double = 4, elapsed: Double = 1.6, recent: Double = 0.4,
                      pieces: Int = 6, gap: Double = 0.6) -> SynthesisProgress {
            SynthesisProgress(chunkIndex: 0, generatedAudioDuration: audio,
                generationDuration: elapsed, recentRealTimeFactor: recent, deliveredAudioPieces: pieces, maximumDeliveryGap: gap)
        }
        #expect(!streaming.shouldStart(synthesisIsComplete: false, bufferedDuration: 4))
        #expect(streaming.shouldStartStreaming(progress(), bufferedDuration: 4))
        #expect(!streaming.shouldStartStreaming(progress(pieces: 0), bufferedDuration: 100))
        #expect(!streaming.shouldStartStreaming(progress(audio: 2), bufferedDuration: 100))
        #expect(!streaming.shouldStartStreaming(progress(), bufferedDuration: 2.9))
        #expect(!streaming.shouldStartStreaming(progress(recent: 0.8), bufferedDuration: 100))
        #expect(!streaming.shouldStartStreaming(progress(elapsed: 4), bufferedDuration: 100))
        #expect(!streaming.shouldStartStreaming(progress(gap: 2), bufferedDuration: 4))
        #expect(!streaming.shouldStartStreaming(progress(recent: .nan), bufferedDuration: 100))
        #expect(!streaming.shouldStartStreaming(progress(), bufferedDuration: .infinity))
        #expect(!PlaybackBufferPolicy(mode: .completeFirst, rate: 1, estimator: estimator)
            .shouldStartStreaming(progress(), bufferedDuration: 100))
        #expect(!PlaybackBufferPolicy(mode: .adaptive, rate: 2, estimator: estimator)
            .shouldStartStreaming(progress(), bufferedDuration: 100))
        var slow = estimator
        slow.record(SynthesisMetrics(chunkIndex: 0, generationDuration: 10, audioDuration: 8))
        #expect(!PlaybackBufferPolicy(mode: .adaptive, rate: 1, estimator: slow)
            .shouldStartStreaming(progress(), bufferedDuration: 100))
    }

    @Test("Early streaming reserve covers variable arrivals and chunk-boundary delays")
    func streamingDeliveryTimeline() {
        let streaming = PlaybackBufferPolicy(mode: .adaptive, rate: 1.2,
            estimator: SynthesisPerformanceEstimator())
        var elapsed = 0.0
        var delivered = 0.0
        var firstStart: Double?
        var largestGap = 0.0
        var recent: [Double] = []
        for index in 0..<80 {
            let gap = index == 0 ? 0.8 : index.isMultiple(of: 20) ? 1.4 : 0.25
            elapsed += gap
            if let firstStart { #expect(delivered >= (elapsed - firstStart) * 1.2) }
            delivered += 0.74
            largestGap = max(largestGap, gap)
            recent.append(gap)
            if recent.count > 4 { recent.removeFirst() }
            let progress = SynthesisProgress(chunkIndex: 0, generatedAudioDuration: delivered,
                generationDuration: elapsed, recentRealTimeFactor: recent.reduce(0, +) / (Double(recent.count) * 0.74),
                deliveredAudioPieces: index + 1, maximumDeliveryGap: largestGap)
            if firstStart == nil, streaming.shouldStartStreaming(progress, bufferedDuration: delivered) {
                firstStart = elapsed
            }
        }
        #expect(firstStart != nil)
        #expect((firstStart ?? elapsed) < 3)
    }

    @Test("Playback modes choose distinct baseline leads")
    func modeBaselines() {
        let estimator = SynthesisPerformanceEstimator()

        #expect(
            policy(.progressive, estimator: estimator).preferredSourceLead
                == 1.2
        )
        #expect(
            policy(.buffered, estimator: estimator).preferredSourceLead
                == 2.5
        )
        #expect(
            policy(.completeFirst, estimator: estimator).preferredSourceLead
                == .infinity
        )
    }

    @Test("Complete-first waits for synthesis completion")
    func completeFirst() {
        let policy = policy(.completeFirst)

        #expect(
            !policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 10_000
            )
        )
        #expect(
            policy.shouldStart(
                synthesisIsComplete: true,
                bufferedDuration: 0
            )
        )
    }

    @Test("Adaptive playback waits for a measured generation rate")
    func adaptiveWaitsForMeasurement() {
        let unmeasured = policy(.adaptive)
        #expect(!unmeasured.streamingIsSustainable)
        #expect(
            !unmeasured.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 100
            )
        )

        var estimator = SynthesisPerformanceEstimator()
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 1,
                audioDuration: 4
            )
        )
        let measured = policy(.adaptive, estimator: estimator)
        #expect(measured.streamingIsSustainable)
        #expect(
            measured.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 4
            )
        )
    }

    @Test("Existing adaptive streaming retains its smaller startup buffer")
    func incrementalStreamingUnchanged() {
        var estimator = SynthesisPerformanceEstimator()
        estimator.record(SynthesisMetrics(chunkIndex: 0, generationDuration: 3, audioDuration: 4))
        let streaming = PlaybackBufferPolicy(mode: .adaptive, rate: 1, estimator: estimator)
        #expect(streaming.shouldStart(synthesisIsComplete: false,
            bufferedDuration: 0.15, estimatedRemainingDuration: 20))
        estimator = SynthesisPerformanceEstimator()
        estimator.record(SynthesisMetrics(chunkIndex: 0, generationDuration: 8, audioDuration: 4))
        let slowStreaming = PlaybackBufferPolicy(mode: .adaptive, rate: 1, estimator: estimator)
        #expect(slowStreaming.shouldStart(synthesisIsComplete: false,
            bufferedDuration: 6.41, estimatedRemainingDuration: 6))
    }

    @Test("Known-sustainable generation starts with minimal buffer")
    func observedLatency() {
        var estimator = SynthesisPerformanceEstimator()
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 3,
                audioDuration: 10
            )
        )
        let policy = policy(.progressive, rate: 1.5, estimator: estimator)

        #expect(abs(policy.preferredSourceLead - 5.1) < 0.000_001)
        #expect(
            !policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 0.14
            )
        )
        #expect(
            policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 0.15
            )
        )
    }

    @Test("Unsustainable generation waits for completion after an underrun")
    func unsustainableGeneration() {
        var estimator = SynthesisPerformanceEstimator()
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 9.5,
                audioDuration: 10
            )
        )
        let policy = policy(.progressive, estimator: estimator)

        #expect(!policy.streamingIsSustainable)
        #expect(
            !policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 100
            )
        )
        #expect(
            policy.shouldStart(
                synthesisIsComplete: true,
                bufferedDuration: 0
            )
        )
    }

    @Test("Playback speed participates in sustainability")
    func rateAdjustedSustainability() {
        var estimator = SynthesisPerformanceEstimator()
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: 6,
                audioDuration: 10
            )
        )

        #expect(policy(.progressive, rate: 1, estimator: estimator)
            .streamingIsSustainable)
        #expect(!policy(.progressive, rate: 2, estimator: estimator)
            .streamingIsSustainable)
    }

    @Test("Unknown generation speed waits for the baseline lead")
    func unknownSpeedWaitsForBaseline() {
        let policy = policy(.progressive)

        #expect(
            !policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 1.19
            )
        )
        #expect(
            policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 1.2
            )
        )
    }

    @Test("Estimator is bounded and uses a conservative percentile")
    func boundedEstimator() {
        var estimator = SynthesisPerformanceEstimator()
        for index in 0..<20 {
            estimator.record(
                SynthesisMetrics(
                    chunkIndex: index,
                    generationDuration: Double(index),
                    audioDuration: 10
                )
            )
        }

        #expect(
            estimator.observations.count
                == SynthesisPerformanceEstimator.maximumObservationCount
        )
        #expect(estimator.observations.first?.chunkIndex == 8)
        #expect(estimator.conservativeGenerationDuration == 18)
    }

    @Test("Invalid observations do not influence policy")
    func invalidObservations() {
        var estimator = SynthesisPerformanceEstimator()
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 0,
                generationDuration: .nan,
                audioDuration: 1
            )
        )
        estimator.record(
            SynthesisMetrics(
                chunkIndex: 1,
                generationDuration: 1,
                audioDuration: 0
            )
        )

        #expect(!estimator.hasObservations)
    }

    private func policy(
        _ mode: PlaybackMode,
        rate: Double = 1,
        estimator: SynthesisPerformanceEstimator =
            SynthesisPerformanceEstimator()
    ) -> PlaybackBufferPolicy {
        PlaybackBufferPolicy(
            mode: mode,
            rate: rate,
            estimator: estimator
        )
    }
}
