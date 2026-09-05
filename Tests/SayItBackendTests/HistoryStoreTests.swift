import Foundation
import SayItCore
import SayItProtocol
import SwiftData
import Testing
@testable import SayItBackend

@Suite("Backend history storage", .serialized)
@MainActor
struct HistoryStoreTests {
    @Test("Corrupt and out-of-bounds history timing safely falls back to unaligned replay")
    func corruptTiming() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItTimingTests")
        defer { fixture.remove() }
        let store = try HistoryStore(directories: fixture.directories)
        let request = try makeRequest(text: "Short text", title: "Timing")
        try store.begin(request)
        try store.complete(id: request.id, duration: 2, audioRelativePath: "test.m4a", audioByteCount: 0)
        let context = ModelContext(store.container)
        let item = try #require(context.fetch(FetchDescriptor<SpeechItem>()).first)
        for data in [
            Data([0xff]),
            try JSONEncoder().encode([
                PlaybackTextChunk(textStart: 0, textEnd: 1000, audioStart: 0, audioEnd: 2)
            ]),
            try JSONEncoder().encode([
                PlaybackTextChunk(textStart: 0, textEnd: 5, audioStart: 1, audioEnd: 0.5)
            ])
        ] {
            item.playbackTimingData = data
            try context.save()
            let reloaded = try HistoryStore(directories: fixture.directories)
            #expect(try reloaded.playbackTiming(id: request.id).isEmpty)
        }
    }

    @Test("History persists uneven timing through reload and clears it on failure")
    func durableTiming() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItTimingTests")
        defer { fixture.remove() }
        let store = try HistoryStore(directories: fixture.directories)
        let request = try makeRequest(text: "First passage. Second passage.", title: "Timing")
        try store.begin(request)
        #expect(try store.playbackTiming(id: request.id).isEmpty)
        let anchors = [
            PlaybackTextChunk(textStart: 0, textEnd: 14, audioStart: 0, audioEnd: 120),
            PlaybackTextChunk(textStart: 15, textEnd: 30, audioStart: 121, audioEnd: 180)
        ]
        try store.complete(
            id: request.id, duration: 180, audioRelativePath: "timing.m4a",
            audioByteCount: 0, spokenChunks: anchors
        )
        let reloaded = try HistoryStore(directories: fixture.directories)
        #expect(try reloaded.playbackTiming(id: request.id) == anchors)
        try reloaded.markIncomplete(id: request.id, state: .failed)
        #expect(try reloaded.playbackTiming(id: request.id).isEmpty)
        #expect(try reloaded.playbackTiming(id: UUID()).isEmpty)
    }

    @Test("History follows generating, completed, failed, and pinned states")
    func historyLifecycle() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItHistoryTests")
        defer { fixture.remove() }
        let store = try HistoryStore(directories: fixture.directories)
        let request = try makeRequest(
            text: "A durable history entry.",
            title: "Durable history",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        try store.begin(request)
        var item = try #require(store.items.first)
        #expect(item.id == request.id)
        #expect(item.state == .generating)
        #expect(item.voiceMode == .standard)
        #expect(store.search("durable").map(\.id) == [request.id])
        #expect(store.search("ENTRY").map(\.id) == [request.id])
        #expect(store.search("").map(\.id) == [request.id])
        #expect(store.audioURL(for: item) == nil)

        let relativePath = "\(request.id.uuidString).m4a"
        let audioURL = fixture.directories.historyAudio.appending(
            path: relativePath
        )
        try Data([1, 2, 3, 4]).write(to: audioURL)
        try store.complete(
            id: request.id,
            duration: 2.5,
            audioRelativePath: relativePath,
            audioByteCount: 4
        )
        item = try #require(store.items.first)
        #expect(item.state == .completed)
        #expect(item.duration == 2.5)
        #expect(store.audioURL(for: item) == audioURL)

        try store.togglePinned(id: request.id)
        #expect(store.items.first?.isPinned == true)
        try store.markIncomplete(
            id: request.id,
            state: .failed,
            code: "synthesis.failed"
        )
        item = try #require(store.items.first)
        #expect(item.state == .failed)
        #expect(item.duration == 0)
        #expect(item.audioRelativePath == nil)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        let reloaded = try HistoryStore(directories: fixture.directories)
        #expect(reloaded.items.first?.id == request.id)
        #expect(reloaded.items.first?.isPinned == true)
        #expect(reloaded.items.first?.state == .failed)
    }

    @Test("Removal deletes associated audio and unknown IDs are no-ops")
    func removalAndUnknownIDs() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItHistoryTests")
        defer { fixture.remove() }
        let store = try HistoryStore(directories: fixture.directories)
        let first = try makeRequest(text: "First", title: "First")
        let second = try makeRequest(text: "Second", title: "Second")
        try store.begin(first)
        try store.begin(second)

        let firstPath = "\(first.id.uuidString).m4a"
        let firstURL = fixture.directories.historyAudio.appending(path: firstPath)
        try Data([1]).write(to: firstURL)
        try store.complete(
            id: first.id,
            duration: 1,
            audioRelativePath: firstPath,
            audioByteCount: 1
        )

        let unknown = UUID()
        try store.complete(
            id: unknown,
            duration: 9,
            audioRelativePath: "unknown.m4a",
            audioByteCount: 9
        )
        try store.markIncomplete(id: unknown, state: .canceled)
        try store.togglePinned(id: unknown)
        try store.remove(id: unknown)
        #expect(store.items.count == 2)

        try store.remove(id: first.id)
        #expect(store.items.map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        try store.removeAll()
        #expect(store.items.isEmpty)
    }

    @Test("Retention removes old unpinned history while preserving pinned items")
    func retentionIntegration() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItHistoryTests")
        defer { fixture.remove() }
        let store = try HistoryStore(directories: fixture.directories)
        let old = try makeRequest(
            text: "Old item",
            title: "Old",
            createdAt: .now.addingTimeInterval(-100 * 24 * 60 * 60)
        )
        let pinned = try makeRequest(
            text: "Pinned item",
            title: "Pinned",
            createdAt: .now.addingTimeInterval(-100 * 24 * 60 * 60)
        )
        try store.begin(old)
        try store.begin(pinned)
        try store.togglePinned(id: pinned.id)

        try store.enforceRetention(period: .thirtyDays, quotaBytes: .max)

        #expect(store.items.map(\.id) == [pinned.id])
    }

    private func makeRequest(
        text: String,
        title: String,
        createdAt: Date = .now
    ) throws -> SpeechRequest {
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )
        return SpeechRequest(
            cleanedText: CleanedText(
                text: text,
                title: title,
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: model.defaultVoice,
            language: "en",
            source: .frontend,
            createdAt: createdAt
        )
    }
}
