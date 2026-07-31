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
        let frameCount = min(
            Int64(requestedFrameCount),
            availableFrameCount
        )
        guard frameCount > 0 else { return [] }
        guard frameCount <= Int64(Int.max / MemoryLayout<Float>.stride) else {
            throw CocoaError(.fileReadTooLarge)
        }

        let byteOffset = UInt64(startFrame)
            * UInt64(MemoryLayout<Float>.stride)
        let byteCount = Int(frameCount) * MemoryLayout<Float>.stride
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: byteOffset)
        let data = try handle.read(upToCount: byteCount) ?? Data()
        guard data.count == byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var samples = [Float](repeating: 0, count: Int(frameCount))
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return samples
    }
}
