import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Backend persistence", .serialized)
struct BackendPersistenceTests {
    @Test("Selection identity is optional in older pending job records")
    func selectionIdentityCompatibility() throws {
        let original = PendingSpeechJob(
            submission: SpeechSubmission(text: "Text", source: .selection),
            cleanedText: nil,
            selectionIdentity: "Text"
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PendingSpeechJob.self, from: data)
        #expect(restored.selectionIdentity == "Text")
        var legacy = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacy.removeValue(forKey: "selectionIdentity")
        let decoded = try JSONDecoder().decode(
            PendingSpeechJob.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.selectionIdentity == nil)
        #expect(decoded.submission.text == "Text")
    }

    @Test("Settings use defaults for missing and corrupt files")
    @MainActor
    func settingsDefaultsAndCorruptionRecovery() throws {
        let fixture = try TemporaryBackendFixture()
        defer { fixture.remove() }

        let missing = BackendSettingsStore(
            directory: fixture.directories.applicationSupport
        )
        #expect(missing.value == BackendSettingsSnapshot())

        try Data("not-json".utf8).write(
            to: fixture.directories.applicationSupport.appending(
                path: "Backend Settings.json"
            )
        )
        let corrupt = BackendSettingsStore(
            directory: fixture.directories.applicationSupport
        )
        #expect(corrupt.value == BackendSettingsSnapshot())
    }

    @Test("Settings persist and accept both HTTP port boundaries")
    @MainActor
    func settingsRoundTripAndPortBoundaries() throws {
        let fixture = try TemporaryBackendFixture()
        defer { fixture.remove() }
        let store = BackendSettingsStore(
            directory: fixture.directories.applicationSupport
        )

        var settings = store.value
        settings.httpPort = 1_024
        settings.playbackRate = 1.5
        settings.activeLanguage = "de"
        try store.update(settings)
        #expect(store.value == settings)
        let reloaded = BackendSettingsStore(
            directory: fixture.directories.applicationSupport
        ).value
        #expect(reloaded.httpPort == settings.httpPort)
        #expect(reloaded.playbackRate == settings.playbackRate)
        #expect(reloaded.activeLanguage == settings.activeLanguage)
        #expect(
            reloaded.voiceSelections[settings.activeModelID]
                == .preset(settings.activeVoice)
        )

        settings.httpPort = 65_535
        try store.update(settings)
        #expect(store.value.httpPort == 65_535)
    }

    @Test("Settings reject privileged and overflowing HTTP ports")
    @MainActor
    func settingsRejectInvalidPorts() throws {
        let fixture = try TemporaryBackendFixture()
        defer { fixture.remove() }
        let store = BackendSettingsStore(
            directory: fixture.directories.applicationSupport
        )

        for port in [0, 1_023, 65_536, Int.max] {
            var settings = store.value
            settings.httpPort = port
            do {
                try store.update(settings)
                Issue.record("Expected port \(port) to be rejected")
            } catch let failure as ServiceFailure {
                #expect(failure.code == "settings.invalid_http_port")
            }
        }
    }

    @Test("A failed settings write preserves the last durable value")
    @MainActor
    func failedSettingsWriteIsTransactional() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "SayItMissingSettings-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let store = BackendSettingsStore(directory: missingDirectory)
        let original = store.value
        var changed = original
        changed.playbackRate = 1.75

        #expect(throws: (any Error).self) {
            try store.update(changed)
        }
        #expect(store.value == original)
    }

    @Test("Job journals round-trip every queue component")
    @MainActor
    func jobJournalRoundTrip() throws {
        let fixture = try TemporaryBackendFixture()
        defer { fixture.remove() }
        let store = JobJournalStore(
            directory: fixture.directories.applicationSupport
        )
        let active = SpeechJob(source: .frontend, title: "Active")
        let queued = SpeechJob(source: .http, title: "Queued")
        let pending = PendingSpeechJob(
            submission: SpeechSubmission(
                text: "Queued text",
                source: .http
            ),
            cleanedText: nil
        )
        let journal = JobJournal(
            jobs: [active, queued],
            pendingJobs: [queued.id: pending],
            queuedJobIDs: [queued.id],
            activeJobID: active.id
        )

        #expect(store.load() == nil)
        try store.save(journal)
        let restored = try #require(store.load())
        #expect(restored.jobs.map(\.id) == [active.id, queued.id])
        #expect(restored.pendingJobs[queued.id]?.submission.text == "Queued text")
        #expect(restored.queuedJobIDs == [queued.id])
        #expect(restored.activeJobID == active.id)
    }

    @Test("Job journals isolate corrupt data and surface write failures")
    @MainActor
    func jobJournalFailureBoundaries() throws {
        let fixture = try TemporaryBackendFixture()
        defer { fixture.remove() }
        let store = JobJournalStore(
            directory: fixture.directories.applicationSupport
        )
        try Data([0xFF, 0x00]).write(
            to: fixture.directories.applicationSupport.appending(
                path: "Speech Jobs.json"
            )
        )
        #expect(store.load() == nil)

        let missingDirectory = fixture.root.appending(
            path: "missing",
            directoryHint: .isDirectory
        )
        let failingStore = JobJournalStore(directory: missingDirectory)
        #expect(throws: (any Error).self) {
            try failingStore.save(
                JobJournal(
                    jobs: [],
                    pendingJobs: [:],
                    queuedJobIDs: [],
                    activeJobID: nil
                )
            )
        }
    }
}

struct TemporaryBackendFixture {
    let root: URL
    let directories: AppDirectories

    init(prefix: String = "SayItBackendTests") throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "\(prefix)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        directories = try AppDirectories.testing(root: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
