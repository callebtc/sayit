import Foundation
import SayItCore

struct PlaybackBufferPolicy: Sendable {
    static let progressiveBaseLead: TimeInterval = 1.2
    static let bufferedBaseLead: TimeInterval = 2.5
    static let minimumSustainableStartBuffer: TimeInterval = 0.15
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
        case .buffered, .adaptive:
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
        if mode == .adaptive, !estimator.hasObservations {
            return false
        }
        guard estimator.hasObservations else { return true }
        return estimator.conservativeRealTimeFactor * max(rate, 0)
            < Self.sustainableLoadLimit
    }

    func shouldStart(
        synthesisIsComplete: Bool,
        bufferedDuration: TimeInterval,
        estimatedRemainingDuration: TimeInterval = 0
    ) -> Bool {
        if synthesisIsComplete {
            return true
        }
        if mode == .adaptive, estimator.hasObservations,
           !streamingIsSustainable {
            let adjustedLoad = estimator.conservativeRealTimeFactor
                * max(rate, 0)
            let requiredLead = max(adjustedLoad - 1, 0)
                * max(estimatedRemainingDuration, 0)
                + Self.generationSafetyMargin * max(rate, 1)
            return bufferedDuration >= requiredLead
        }
        guard streamingIsSustainable else { return false }
        if estimator.hasObservations {
            return bufferedDuration >= Self.minimumSustainableStartBuffer
        }
        return bufferedDuration >= preferredSourceLead
    }
}
