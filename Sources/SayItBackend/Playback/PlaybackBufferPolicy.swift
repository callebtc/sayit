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

    /// Qualify startup from delivered pieces before the first logical chunk ends.
    /// Frame-only progress must never qualify: those samples are not playable yet.
    func shouldStartStreaming(_ progress: SynthesisProgress,
                              bufferedDuration: TimeInterval) -> Bool {
        guard mode == .adaptive,
              progress.deliveredAudioPieces >= 4,
              progress.generatedAudioDuration.isFinite, progress.generatedAudioDuration >= 3,
              progress.generationDuration.isFinite, progress.generationDuration > 0,
              progress.recentRealTimeFactor.isFinite, progress.recentRealTimeFactor > 0,
              progress.maximumDeliveryGap.isFinite, progress.maximumDeliveryGap > 0,
              progress.initialGenerationDuration.isFinite, progress.initialGenerationDuration >= 0,
              progress.initialGenerationDuration < progress.generationDuration,
              progress.initialAudioDuration.isFinite, progress.initialAudioDuration >= 0,
              progress.initialAudioDuration < progress.generatedAudioDuration,
              bufferedDuration.isFinite, rate.isFinite, rate > 0 else { return false }
        let cumulativeFactor = (progress.generationDuration - progress.initialGenerationDuration)
            / (progress.generatedAudioDuration - progress.initialAudioDuration)
        let ongoingFactor = max(progress.recentRealTimeFactor, estimator.conservativeRealTimeFactor)
        // Prefill has already been paid for and its samples are buffered. Require
        // cumulative sustainability and 25% headroom for the recent delivery rate.
        // Two observed delivery gaps reserve time for a later chunk's prefill.
        guard cumulativeFactor * rate < Self.sustainableLoadLimit,
              ongoingFactor * rate * 1.25 < Self.sustainableLoadLimit else { return false }
        let reserve = max(Self.bufferedBaseLead,
                          progress.maximumDeliveryGap * 2 + Self.generationSafetyMargin)
        return bufferedDuration >= reserve * max(rate, 1)
    }

    func shouldStart(
        synthesisIsComplete: Bool,
        bufferedDuration: TimeInterval,
        estimatedRemainingDuration: TimeInterval = 0
    ) -> Bool {
        if synthesisIsComplete {
            return true
        }
        if mode == .adaptive, estimator.hasObservations, !streamingIsSustainable {
            let adjustedLoad = estimator.conservativeRealTimeFactor * max(rate, 0)
            let requiredLead = max(adjustedLoad - 1, 0) * max(estimatedRemainingDuration, 0)
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
