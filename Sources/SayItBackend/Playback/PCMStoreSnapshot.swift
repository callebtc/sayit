import Darwin
import Foundation

struct PCMStoreSnapshot: Sendable {
    private final class RetainedDescriptor: @unchecked Sendable {
        let rawValue: Int32

        init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            _ = Darwin.close(rawValue)
        }
    }

    let url: URL
    let sampleRate: Double
    let frameCount: Int64
    private let ownedDescriptor: RetainedDescriptor?

    init(
        url: URL,
        sampleRate: Double,
        frameCount: Int64,
        duplicatedDescriptor: Int32? = nil
    ) {
        self.url = url
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.ownedDescriptor = duplicatedDescriptor.map(RetainedDescriptor.init)
    }

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

        return try withOpenFileDescriptor { fd in
            try PCMStore.preadFrames(
                from: fd,
                startingAt: startFrame,
                count: Int(readCount)
            )
        }
    }

    func withOpenFileDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        if let ownedDescriptor {
            return try withExtendedLifetime(ownedDescriptor) {
                try body(ownedDescriptor.rawValue)
            }
        }
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { _ = Darwin.close(fd) }
        return try body(fd)
    }
}
