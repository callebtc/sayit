import Darwin
import Foundation

final class PCMStore {
    let url: URL
    let sampleRate: Double
    private(set) var frameCount: Int64 = 0

    private let fileDescriptor: Int32
    private var writeByteOffset: off_t = 0

    private let maxTailFrames: Int
    private var tailSamples: [Float] = []
    private var tailHeadOffset: Int = 0
    private var tailStartFrame: Int64 = 0

    init(
        sampleRate: Double,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= 1_000_000 else {
            throw PlaybackError.invalidSampleRate
        }
        self.sampleRate = sampleRate
        maxTailFrames = max(Int((sampleRate * 32).rounded()), 65_536)
        url = directory.appending(
            path: "sayit-playback-\(UUID().uuidString).pcm"
        )

        let fd = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)
        fileDescriptor = fd
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let allFinite = samples.withUnsafeBufferPointer { buffer in
            for sample in buffer where !sample.isFinite {
                return false
            }
            return true
        }
        guard allFinite else {
            throw PlaybackError.invalidSamples
        }
        guard frameCount <= Int64.max - Int64(samples.count) else {
            throw PlaybackError.audioTooLarge
        }

        try samples.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            let total = rawBuffer.count
            while written < total {
                let result = Darwin.pwrite(
                    fileDescriptor,
                    base.advanced(by: written),
                    total - written,
                    writeByteOffset + off_t(written)
                )
                if result > 0 {
                    written += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            writeByteOffset += off_t(total)
        }

        frameCount += Int64(samples.count)
        appendToTailCache(samples)
    }

    func readFrames(
        startingAt startFrame: Int64,
        count requestedFrameCount: Int
    ) throws -> [Float] {
        guard startFrame >= 0, requestedFrameCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let availableFrameCount = max(frameCount - startFrame, 0)
        let readCount = min(Int64(requestedFrameCount), availableFrameCount)
        guard readCount > 0 else { return [] }
        guard readCount <= Int64(Int.max / MemoryLayout<Float>.stride) else {
            throw CocoaError(.fileReadTooLarge)
        }

        let liveTailCount = tailSamples.count - tailHeadOffset
        if liveTailCount > 0,
           startFrame >= tailStartFrame,
           startFrame + readCount <= tailStartFrame + Int64(liveTailCount) {
            let localStart = tailHeadOffset + Int(startFrame - tailStartFrame)
            return Array(tailSamples[localStart..<(localStart + Int(readCount))])
        }

        return try Self.preadFrames(
            from: fileDescriptor,
            startingAt: startFrame,
            count: Int(readCount)
        )
    }

    func snapshot(synchronize: Bool = true) throws -> PCMStoreSnapshot {
        if synchronize {
            if Darwin.fsync(fileDescriptor) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let duplicated = Darwin.dup(fileDescriptor)
        guard duplicated >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return PCMStoreSnapshot(
            url: url,
            sampleRate: sampleRate,
            frameCount: frameCount,
            duplicatedDescriptor: duplicated
        )
    }

    private func appendToTailCache(_ samples: [Float]) {
        if samples.count >= maxTailFrames {
            let keepStart = samples.count - maxTailFrames
            tailSamples = Array(samples[keepStart...])
            tailHeadOffset = 0
            tailStartFrame = frameCount - Int64(maxTailFrames)
            return
        }
        tailSamples.append(contentsOf: samples)
        let liveCount = tailSamples.count - tailHeadOffset
        if liveCount > maxTailFrames {
            let overflow = liveCount - maxTailFrames
            tailHeadOffset += overflow
            tailStartFrame += Int64(overflow)
            if tailHeadOffset >= maxTailFrames {
                tailSamples.removeFirst(tailHeadOffset)
                tailHeadOffset = 0
            }
        }
    }

    static func preadFrames(
        from fd: Int32,
        startingAt startFrame: Int64,
        count: Int
    ) throws -> [Float] {
        let byteOffset = off_t(startFrame) * off_t(MemoryLayout<Float>.stride)
        let byteCount = count * MemoryLayout<Float>.stride
        return try [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            guard let base = buffer.baseAddress else {
                initializedCount = 0
                return
            }
            let rawBase = UnsafeMutableRawPointer(base)
            var bytesRead = 0
            while bytesRead < byteCount {
                let result = Darwin.pread(
                    fd,
                    rawBase.advanced(by: bytesRead),
                    byteCount - bytesRead,
                    byteOffset + off_t(bytesRead)
                )
                if result > 0 {
                    bytesRead += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else if result == 0 {
                    throw CocoaError(.fileReadCorruptFile)
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            initializedCount = count
        }
    }
}
