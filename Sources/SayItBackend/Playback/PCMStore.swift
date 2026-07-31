import Foundation

final class PCMStore {
    let url: URL
    let sampleRate: Double
    private(set) var frameCount: Int64 = 0

    private var writeHandle: FileHandle?

    init(
        sampleRate: Double,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
        self.sampleRate = sampleRate
        url = directory.appending(
            path: "sayit-playback-\(UUID().uuidString).pcm"
        )

        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            writeHandle = try FileHandle(forWritingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit {
        try? writeHandle?.close()
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard samples.allSatisfy(\.isFinite) else {
            throw PlaybackError.invalidSamples
        }
        guard frameCount <= Int64.max - Int64(samples.count) else {
            throw PlaybackError.audioTooLarge
        }
        guard let writeHandle else {
            throw CocoaError(.fileWriteUnknown)
        }

        let data = samples.withUnsafeBytes { Data($0) }
        try writeHandle.write(contentsOf: data)
        frameCount += Int64(samples.count)
    }

    func readFrames(
        startingAt startFrame: Int64,
        count: Int
    ) throws -> [Float] {
        try snapshot(synchronize: false).readFrames(
            startingAt: startFrame,
            count: count
        )
    }

    func snapshot(synchronize: Bool = true) throws -> PCMStoreSnapshot {
        if synchronize {
            try writeHandle?.synchronize()
        }
        return PCMStoreSnapshot(
            url: url,
            sampleRate: sampleRate,
            frameCount: frameCount
        )
    }
}
