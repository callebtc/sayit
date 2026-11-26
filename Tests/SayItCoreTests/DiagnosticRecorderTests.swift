import Foundation
import Testing
@testable import SayItCore

@Suite("Diagnostic redaction and persistence")
struct DiagnosticRecorderTests {
    @Test("Only stable allowlisted codes are accepted")
    func safeCodes() {
        #expect(DiagnosticRecorder.isSafeCode("model.load_failed"))
        #expect(DiagnosticRecorder.isSafeCode("download_checksum_42"))
        #expect(!DiagnosticRecorder.isSafeCode("Copied text: private words"))
        #expect(!DiagnosticRecorder.isSafeCode("/local/path/model"))
        #expect(!DiagnosticRecorder.isSafeCode("TOKEN=secret"))
    }

    @Test("Recorder appends via persistent handle, clears, and resumes cleanly")
    func appendAndClearLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticRecorder-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "diagnostics.jsonl")

        let recorder = DiagnosticRecorder(fileURL: fileURL)
        await recorder.record(DiagnosticEvent(severity: .info, category: .lifecycle, code: "service.started"))
        await recorder.record(DiagnosticEvent(severity: .warning, category: .playback, code: "playback.rebuffered"))
        await recorder.record(DiagnosticEvent(severity: .error, category: .model, code: "model.load_failed"))
        // Unsafe codes must be ignored.
        await recorder.record(DiagnosticEvent(severity: .error, category: .lifecycle, code: "PRIVATE TEXT"))

        let recorded = await recorder.events()
        #expect(recorded.map(\.code) == ["service.started", "playback.rebuffered", "model.load_failed"])

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(persisted.count == 3)

        // Reloading from disk recovers the persisted JSONL events.
        let reloaded = DiagnosticRecorder(fileURL: fileURL)
        #expect(await reloaded.events().map(\.code) == ["service.started", "playback.rebuffered", "model.load_failed"])

        // Clear removes both in-memory and on-disk records, and subsequent writes recreate the log.
        try await recorder.clear()
        #expect(await recorder.events().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        await recorder.record(DiagnosticEvent(severity: .info, category: .lifecycle, code: "service.recovered"))
        #expect(await recorder.events().map(\.code) == ["service.recovered"])
        let recreated = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(recreated.count == 1)
    }

    @Test("Recorder rotates expired and oversized log files")
    func rotatesExpiredAndOversizedLogs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticRotation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Expired log (> 7 days old) rotates before writing the new event.
        let expiredURL = directory.appending(path: "expired.jsonl")
        let oldEventData = try JSONEncoder.sayIt.encode(
            DiagnosticEvent(severity: .info, category: .lifecycle, code: "old.event")
        )
        try (oldEventData + Data([0x0A])).write(to: expiredURL)
        let eightDaysAgo = Date.now.addingTimeInterval(-(DiagnosticRecorder.maximumAge + 3_600))
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: expiredURL.path)

        let expiredRecorder = DiagnosticRecorder(fileURL: expiredURL)
        await expiredRecorder.record(DiagnosticEvent(severity: .info, category: .lifecycle, code: "fresh.event"))
        let expiredContents = try String(contentsOf: expiredURL, encoding: .utf8)
        #expect(!expiredContents.contains("old.event"))
        #expect(expiredContents.contains("fresh.event"))

        // Oversized log (>= maximumByteCount) rotates before writing the new event.
        let oversizedURL = directory.appending(path: "oversized.jsonl")
        try Data(count: Int(DiagnosticRecorder.maximumByteCount)).write(to: oversizedURL)

        let oversizedRecorder = DiagnosticRecorder(fileURL: oversizedURL)
        await oversizedRecorder.record(DiagnosticEvent(severity: .info, category: .lifecycle, code: "rotated.event"))
        let attributes = try FileManager.default.attributesOfItem(atPath: oversizedURL.path)
        let size = try #require((attributes[.size] as? NSNumber)?.intValue)
        #expect(size < 1_024)
        let oversizedContents = try String(contentsOf: oversizedURL, encoding: .utf8)
        #expect(oversizedContents.contains("rotated.event"))
    }
}
