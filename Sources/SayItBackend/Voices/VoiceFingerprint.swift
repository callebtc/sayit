import Foundation

enum VoiceFingerprint {
    static func make(samples: [Float], barCount: Int = 64) -> [Float] {
        guard !samples.isEmpty, barCount > 0 else { return [] }
        let windowSize = max(samples.count / barCount, 1)
        return (0..<barCount).map { index in
            let lower = min(index * windowSize, samples.count)
            let upper = index == barCount - 1
                ? samples.count
                : min(lower + windowSize, samples.count)
            guard lower < upper else { return 0.08 }
            let energy = samples[lower..<upper].reduce(0.0) {
                $0 + Double($1 * $1)
            }
            let rms = sqrt(energy / Double(upper - lower))
            return Float(min(max(rms * 5, 0.08), 1))
        }
    }
}
