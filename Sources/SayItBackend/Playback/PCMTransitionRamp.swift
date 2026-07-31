import Foundation

enum PCMTransitionRamp {
    static func fadeIn(_ samples: [Float]) -> [Float] {
        ramp(samples, rising: true)
    }

    static func fadeOut(_ samples: [Float]) -> [Float] {
        ramp(samples, rising: false)
    }

    static func fadeInHead(
        _ samples: [Float],
        frameCount: Int
    ) -> [Float] {
        let count = min(max(frameCount, 0), samples.count)
        guard count > 0 else { return samples }
        return fadeIn(Array(samples.prefix(count)))
            + Array(samples.dropFirst(count))
    }

    static func equalPowerCrossfade(
        outgoing: ArraySlice<Float>,
        incoming: ArraySlice<Float>
    ) -> [Float] {
        let count = min(outgoing.count, incoming.count)
        guard count > 0 else { return [] }
        if count == 1 {
            return [safetyLimited(incoming[incoming.startIndex])]
        }
        return (0..<count).map { offset in
            let progress = Double(offset) / Double(count - 1)
            let angle = progress * .pi / 2
            let outgoingSample = outgoing[
                outgoing.index(outgoing.startIndex, offsetBy: offset)
            ]
            let incomingSample = incoming[
                incoming.index(incoming.startIndex, offsetBy: offset)
            ]
            return safetyLimited(
                outgoingSample * Float(cos(angle))
                    + incomingSample * Float(sin(angle))
            )
        }
    }

    static func safetyLimited(_ sample: Float) -> Float {
        min(max(sample, -0.98), 0.98)
    }

    private static func ramp(
        _ samples: [Float],
        rising: Bool
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard samples.count > 1 else { return [0] }
        return samples.enumerated().map { index, sample in
            let progress = Float(index) / Float(samples.count - 1)
            let gain = rising ? progress : 1 - progress
            return safetyLimited(sample * gain)
        }
    }
}
