import Foundation
import SayItCore

struct SynthesisPerformanceEstimator: Sendable {
    static let maximumObservationCount = 12

    private(set) var observations: [SynthesisMetrics] = []

    mutating func record(_ metrics: SynthesisMetrics) {
        guard metrics.generationDuration.isFinite,
              metrics.generationDuration >= 0,
              metrics.audioDuration.isFinite,
              metrics.audioDuration > 0 else {
            return
        }
        observations.append(metrics)
        if observations.count > Self.maximumObservationCount {
            observations.removeFirst(
                observations.count - Self.maximumObservationCount
            )
        }
    }

    var hasObservations: Bool {
        !observations.isEmpty
    }

    var conservativeGenerationDuration: TimeInterval {
        percentile(
            observations.map(\.generationDuration),
            probability: 0.9
        )
    }

    var conservativeRealTimeFactor: Double {
        percentile(
            observations.map(\.realTimeFactor),
            probability: 0.9
        )
    }

    private func percentile(
        _ values: [Double],
        probability: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let boundedProbability = min(max(probability, 0), 1)
        let index = Int(
            ceil(boundedProbability * Double(sorted.count)) - 1
        )
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
