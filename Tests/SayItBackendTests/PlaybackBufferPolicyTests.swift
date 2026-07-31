import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Playback buffer policy")
struct PlaybackBufferPolicyTests {
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

    @Test("Observed generation latency raises the adaptive watermark")
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
                bufferedDuration: 5
            )
        )
        #expect(
            policy.shouldStart(
                synthesisIsComplete: false,
                bufferedDuration: 5.1
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
