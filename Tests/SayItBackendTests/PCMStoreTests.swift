import AVFoundation
import Foundation
import Testing
@testable import SayItBackend

@Suite("Disk-backed PCM storage", .serialized)
struct PCMStoreTests {
    @Test("Appends and range reads preserve exact samples")
    func appendAndRead() throws {
        let fixture = try TemporaryBackendFixture(prefix: "PCMStoreTests")
        defer { fixture.remove() }
        let store = try PCMStore(
            sampleRate: 24_000,
            directory: fixture.root
        )

        try store.append([0.1, 0.2, 0.3])
        try store.append([0.4, 0.5])

        #expect(store.frameCount == 5)
        #expect(
            try store.readFrames(startingAt: 1, count: 3)
                == [0.2, 0.3, 0.4]
        )
        #expect(
            try store.readFrames(startingAt: 4, count: 10)
                == [0.5]
        )
        #expect(try store.readFrames(startingAt: 5, count: 1).isEmpty)
    }

    @Test("Store rejects invalid audio without extending the file")
    func invalidSamples() throws {
        let fixture = try TemporaryBackendFixture(prefix: "PCMStoreTests")
        defer { fixture.remove() }
        let store = try PCMStore(
            sampleRate: 24_000,
            directory: fixture.root
        )

        #expect(throws: PlaybackError.self) {
            try store.append([0, .nan])
        }
        #expect(store.frameCount == 0)
        #expect(
            try store.url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0
        )
    }

    @Test("Temporary PCM is removed when its store is released")
    func cleanup() throws {
        let fixture = try TemporaryBackendFixture(prefix: "PCMStoreTests")
        defer { fixture.remove() }
        var store: PCMStore? = try PCMStore(
            sampleRate: 24_000,
            directory: fixture.root
        )
        let url = try #require(store?.url)
        try store?.append([0.1, 0.2])
        #expect(FileManager.default.fileExists(atPath: url.path))

        store = nil

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Snapshot streams to WAV without a whole-recording array")
    func snapshotWAV() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "PCMStoreTests")
        defer { fixture.remove() }
        let store = try PCMStore(
            sampleRate: 24_000,
            directory: fixture.root
        )
        let samples = (0..<150_000).map { frame in
            Float(sin(Double(frame) / 20) * 0.1)
        }
        try store.append(samples)
        let destination = fixture.root.appending(path: "snapshot.wav")

        try await AudioArchive(directory: fixture.root).writeWAV(
            source: store.snapshot(),
            destination: destination
        )

        let file = try AVAudioFile(forReading: destination)
        #expect(file.length == AVAudioFramePosition(samples.count))
        #expect(file.processingFormat.sampleRate == 24_000)
    }

    @Test("Snapshot streams to a playable M4A")
    func snapshotM4A() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "PCMStoreTests")
        defer { fixture.remove() }
        let store = try PCMStore(
            sampleRate: 24_000,
            directory: fixture.root
        )
        let samples = (0..<120_000).map { frame in
            Float(sin(Double(frame) / 20) * 0.1)
        }
        try store.append(samples)
        let archive = AudioArchive(directory: fixture.root)

        let result = try await archive.writeM4A(
            source: store.snapshot(),
            requestID: UUID()
        )

        let file = try AVAudioFile(
            forReading: fixture.root.appending(path: result.relativePath)
        )
        #expect(file.length == AVAudioFramePosition(samples.count))
        #expect(file.processingFormat.sampleRate == 24_000)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.path
        )
        #expect(!names.contains { $0.contains(".partial.") })
    }
}
