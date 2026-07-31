import Foundation

struct PCMFrameScheduler: Equatable {
    let horizonFrameCount: Int64
    let chunkFrameCount: Int64

    private(set) var nextFrame: Int64
    private(set) var scheduledFrameCount: Int64 = 0

    init(
        sampleRate: Double,
        horizonDuration: TimeInterval,
        chunkDuration: TimeInterval,
        startingAt startFrame: Int64 = 0
    ) {
        horizonFrameCount = max(
            Int64((sampleRate * horizonDuration).rounded()),
            1
        )
        chunkFrameCount = max(
            Int64((sampleRate * chunkDuration).rounded()),
            1
        )
        nextFrame = max(startFrame, 0)
    }

    func nextRange(availableFrameCount: Int64) -> Range<Int64>? {
        guard nextFrame < availableFrameCount,
              scheduledFrameCount < horizonFrameCount else {
            return nil
        }
        let available = availableFrameCount - nextFrame
        let horizonRemaining = horizonFrameCount - scheduledFrameCount
        let count = min(chunkFrameCount, available, horizonRemaining)
        guard count > 0 else { return nil }
        return nextFrame..<(nextFrame + count)
    }

    mutating func didSchedule(_ range: Range<Int64>) {
        guard range.lowerBound == nextFrame, !range.isEmpty else { return }
        nextFrame = range.upperBound
        scheduledFrameCount += Int64(range.count)
    }

    mutating func didComplete(frameCount: Int64) {
        scheduledFrameCount = max(scheduledFrameCount - frameCount, 0)
    }

    mutating func reset(startingAt startFrame: Int64) {
        nextFrame = max(startFrame, 0)
        scheduledFrameCount = 0
    }
}
