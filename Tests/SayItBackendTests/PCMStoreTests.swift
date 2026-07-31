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
}

@Suite("Bounded PCM frame scheduler")
struct PCMFrameSchedulerTests {
    @Test("A long recording never schedules beyond its horizon")
    func boundedHorizon() throws {
        let sampleRate = 24_000.0
        var scheduler = PCMFrameScheduler(
            sampleRate: sampleRate,
            horizonDuration: 12,
            chunkDuration: 2
        )
        let fourHours = Int64(sampleRate * 4 * 60 * 60)
        var ranges: [Range<Int64>] = []

        while let range = scheduler.nextRange(
            availableFrameCount: fourHours
        ) {
            ranges.append(range)
            scheduler.didSchedule(range)
        }

        #expect(ranges.count == 6)
        #expect(scheduler.scheduledFrameCount == 12 * 24_000)
        #expect(scheduler.nextFrame == 12 * 24_000)
        #expect(ranges.allSatisfy { $0.count <= 2 * 24_000 })
    }

    @Test("Completions refill one bounded segment at a time")
    func refill() throws {
        var scheduler = PCMFrameScheduler(
            sampleRate: 10,
            horizonDuration: 4,
            chunkDuration: 2
        )
        while let range = scheduler.nextRange(availableFrameCount: 1_000) {
            scheduler.didSchedule(range)
        }

        scheduler.didComplete(frameCount: 20)
        let refill = try #require(
            scheduler.nextRange(availableFrameCount: 1_000)
        )
        scheduler.didSchedule(refill)

        #expect(refill == 40..<60)
        #expect(scheduler.scheduledFrameCount == 40)
    }

    @Test("Seek resets pending and scheduled frame accounting")
    func seekReset() throws {
        var scheduler = PCMFrameScheduler(
            sampleRate: 10,
            horizonDuration: 4,
            chunkDuration: 2
        )
        let initial = try #require(
            scheduler.nextRange(availableFrameCount: 1_000)
        )
        scheduler.didSchedule(initial)

        scheduler.reset(startingAt: 735)

        #expect(scheduler.scheduledFrameCount == 0)
        #expect(
            scheduler.nextRange(availableFrameCount: 1_000) == 735..<755
        )
    }
}
