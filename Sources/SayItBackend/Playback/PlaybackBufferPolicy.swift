import Foundation
import SayItCore

struct PlaybackBufferPolicy: Sendable {
    static let progressiveBaseLead: TimeInterval = 1.2
    static let bufferedBaseLead: TimeInterval = 2.5
    static let generationSafetyMargin: TimeInterval = 0.4
    static let sustainableLoadLimit = 0.92

    let mode: PlaybackMode
    let rate: Double
    let estimator: SynthesisPerformanceEstimator

    var preferredSourceLead: TimeInterval {
        guard mode != .completeFirst else { return .infinity }
        let baseLead: TimeInterval
        switch mode {
        case .progressive:
            baseLead = Self.progressiveBaseLead
        case .buffered:
            baseLead = Self.bufferedBaseLead
        case .completeFirst:
            baseLead = 0
        }
        let observedLead = estimator.hasObservations
            ? estimator.conservativeGenerationDuration
                + Self.generationSafetyMargin
            : 0
        return max(baseLead, observedLead) * max(rate, 1)
    }

    var streamingIsSustainable: Bool {
        guard mode != .completeFirst else { return false }
        guard estimator.hasObservations else { return true }
        return estimator.conservativeRealTimeFactor * max(rate, 0)
            < Self.sustainableLoadLimit
    }

    func shouldStart(
        synthesisIsComplete: Bool,
        bufferedDuration: TimeInterval
    ) -> Bool {
        if synthesisIsComplete {
            return true
        }
        guard streamingIsSustainable else { return false }
        return bufferedDuration >= preferredSourceLead
    }
}
