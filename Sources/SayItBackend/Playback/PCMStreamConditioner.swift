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

    var retainedFrameCount: Int { pendingTail.count }

    func speechStartFrameOffset(
        logicalChunkIndex: Int,
        startsParagraph: Bool,
        paragraphPauseFrameCount: Int
    ) -> Int {
        guard let currentLogicalChunkIndex,
              currentLogicalChunkIndex != logicalChunkIndex,
              startsParagraph, paragraphPauseFrameCount > 0 else { return 0 }
        return pendingTail.count + paragraphPauseFrameCount
    }

    mutating func append(
        _ samples: [Float],
        logicalChunkIndex: Int,
        startsParagraph: Bool,
        paragraphPauseFrameCount: Int
    ) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        let count = samples.count
        var prevIn = previousInput
        var prevOut = previousOutput
        let pole = Self.dcFilterPole
        var hasInvalidSample = false

        let processed = [Float](unsafeUninitializedCapacity: count) { dst, initializedCount in
            samples.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else {
                    initializedCount = 0
                    return
                }
                for index in 0..<count {
                    let sample = srcBase[index]
                    if !sample.isFinite {
                        hasInvalidSample = true
                        initializedCount = index
                        return
                    }
                    let filtered = sample - prevIn + pole * prevOut
                    prevIn = sample
                    prevOut = filtered
                    dstBase[index] = PCMTransitionRamp.safetyLimited(filtered)
                }
                initializedCount = count
            }
        }
        if hasInvalidSample {
            throw PlaybackError.invalidSamples
        }
        previousInput = prevIn
        previousOutput = prevOut

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
            return appendContinuingChunk(processed)
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

    private mutating func appendContinuingChunk(_ processed: [Float]) -> [Float] {
        let tailCount = pendingTail.count
        let incomingCount = processed.count
        let totalCount = tailCount + incomingCount
        guard totalCount > boundaryFrameCount else {
            pendingTail.append(contentsOf: processed)
            return []
        }

        let emitCount = totalCount - boundaryFrameCount
        let output = [Float](unsafeUninitializedCapacity: emitCount) { dst, initializedCount in
            guard let dstBase = dst.baseAddress else {
                initializedCount = 0
                return
            }
            let fromTail = min(emitCount, tailCount)
            if fromTail > 0 {
                pendingTail.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        dstBase.initialize(from: srcBase, count: fromTail)
                    }
                }
            }
            let fromIncoming = emitCount - fromTail
            if fromIncoming > 0 {
                processed.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        dstBase.advanced(by: fromTail).initialize(from: srcBase, count: fromIncoming)
                    }
                }
            }
            initializedCount = emitCount
        }

        if incomingCount >= boundaryFrameCount {
            let splitIndex = incomingCount - boundaryFrameCount
            pendingTail = Array(processed[splitIndex...])
        } else {
            let keepFromTail = boundaryFrameCount - incomingCount
            var nextTail: [Float] = []
            nextTail.reserveCapacity(boundaryFrameCount)
            nextTail.append(contentsOf: pendingTail[(tailCount - keepFromTail)...])
            nextTail.append(contentsOf: processed)
            pendingTail = nextTail
        }
        return output
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
