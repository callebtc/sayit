import Foundation

struct PCMStreamConditioner: Sendable {
    static let boundaryDuration: TimeInterval = 0.008
    static let dcFilterPole: Float = 0.995

    let boundaryFrameCount: Int

    private var currentLogicalChunkIndex: Int?
    private var pendingTail: [Float] = []
    private var previousInput: Float = 0
    private var previousOutput: Float = 0

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
        boundaryFrameCount = max(
            Int((sampleRate * Self.boundaryDuration).rounded()),
            1
        )
    }

    mutating func append(
        _ samples: [Float],
        logicalChunkIndex: Int,
        startsParagraph: Bool,
        paragraphPauseFrameCount: Int
    ) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard samples.allSatisfy(\.isFinite) else {
            throw PlaybackError.invalidSamples
        }

        var processed: [Float] = []
        processed.reserveCapacity(samples.count)
        for sample in samples {
            processed.append(process(sample))
        }
        guard let currentLogicalChunkIndex else {
            self.currentLogicalChunkIndex = logicalChunkIndex
            return holdTail(
                from: PCMTransitionRamp.fadeInHead(
                    processed,
                    frameCount: boundaryFrameCount
                )
            )
        }
        if currentLogicalChunkIndex == logicalChunkIndex {
            return holdTail(from: pendingTail + processed)
        }

        self.currentLogicalChunkIndex = logicalChunkIndex
        if startsParagraph, paragraphPauseFrameCount > 0 {
            return paragraphBoundary(
                incoming: processed,
                pauseFrameCount: paragraphPauseFrameCount
            )
        }
        return crossfadedBoundary(incoming: processed)
    }

    mutating func finish() -> [Float] {
        defer { pendingTail = [] }
        return PCMTransitionRamp.fadeOut(pendingTail)
    }

    private mutating func process(_ sample: Float) -> Float {
        let filtered = sample - previousInput
            + Self.dcFilterPole * previousOutput
        previousInput = sample
        previousOutput = filtered
        return PCMTransitionRamp.safetyLimited(filtered)
    }

    private mutating func holdTail(from samples: [Float]) -> [Float] {
        guard samples.count > boundaryFrameCount else {
            pendingTail = samples
            return []
        }
        let splitIndex = samples.count - boundaryFrameCount
        pendingTail = Array(samples[splitIndex...])
        return Array(samples[..<splitIndex])
    }

    private mutating func crossfadedBoundary(
        incoming: [Float]
    ) -> [Float] {
        let crossfadeCount = min(
            boundaryFrameCount,
            pendingTail.count,
            incoming.count
        )
        guard crossfadeCount > 0 else {
            let prefix = pendingTail
            pendingTail = []
            return prefix + holdTail(
                from: PCMTransitionRamp.fadeInHead(
                    incoming,
                    frameCount: boundaryFrameCount
                )
            )
        }

        let outgoingPrefix = pendingTail.dropLast(crossfadeCount)
        let outgoing = pendingTail.suffix(crossfadeCount)
        let incomingHead = incoming.prefix(crossfadeCount)
        let crossfade = PCMTransitionRamp.equalPowerCrossfade(
            outgoing: outgoing,
            incoming: incomingHead
        )
        pendingTail = []
        let remainder = Array(incoming.dropFirst(crossfadeCount))
        return Array(outgoingPrefix) + crossfade + holdTail(from: remainder)
    }

    private mutating func paragraphBoundary(
        incoming: [Float],
        pauseFrameCount: Int
    ) -> [Float] {
        let outgoing = PCMTransitionRamp.fadeOut(pendingTail)
        pendingTail = []
        let headCount = min(boundaryFrameCount, incoming.count)
        let incomingHead = PCMTransitionRamp.fadeIn(
            Array(incoming.prefix(headCount))
        )
        let remainder = Array(incoming.dropFirst(headCount))
        return outgoing
            + Array(repeating: 0, count: max(pauseFrameCount, 0))
            + incomingHead
            + holdTail(from: remainder)
    }
}
