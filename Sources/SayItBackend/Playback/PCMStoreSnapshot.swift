import Darwin
import Foundation

struct PCMStoreSnapshot: Sendable {
    let url: URL
    let sampleRate: Double
    let frameCount: Int64

    func readFrames(
        startingAt startFrame: Int64,
        count requestedFrameCount: Int
    ) throws -> [Float] {
        guard startFrame >= 0, requestedFrameCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let availableFrameCount = max(frameCount - startFrame, 0)
        let readCount = min(
            Int64(requestedFrameCount),
            availableFrameCount
        )
        guard readCount > 0 else { return [] }
        guard readCount <= Int64(Int.max / MemoryLayout<Float>.stride) else {
            throw CocoaError(.fileReadTooLarge)
        }

        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { _ = Darwin.close(fd) }

        return try PCMStore.preadFrames(
            from: fd,
            startingAt: startFrame,
            count: Int(readCount)
        )
    }

    func withOpenFileDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { _ = Darwin.close(fd) }
        return try body(fd)
    }
}
