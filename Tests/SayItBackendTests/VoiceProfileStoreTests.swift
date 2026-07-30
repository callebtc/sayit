import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Voice profile storage")
struct VoiceProfileStoreTests {
    @Test("Profiles persist atomically and corrupt siblings are isolated")
    @MainActor
    func profilePersistenceAndIsolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let draft = try makeDraft(directories: directories)

        let saved = try store.saveGenerated(draft, name: "  Amber Brook  ")
        #expect(saved.displayName == "Amber Brook")
        #expect(try store.referenceURL(for: #require(store.record(id: saved.id)))
            .lastPathComponent == "reference.wav")

        let corruptDirectory = directories.voiceProfiles
            .appending(path: "omnivoice")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: corruptDirectory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: corruptDirectory.appending(path: "profile.json")
        )

        let reloaded = VoiceProfileStore(directories: directories)
        #expect(reloaded.snapshots.map(\.id) == [saved.id])
        #expect(reloaded.record(id: saved.id)?.transcript == draft.transcript)
    }

    @Test("Names are unique per model and path traversal is rejected")
    @MainActor
    func validationBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let draft = try makeDraft(directories: directories)
        _ = try store.saveGenerated(draft, name: "Silver Lark")

        #expect(throws: (any Error).self) {
            _ = try store.saveGenerated(draft, name: "silver lark")
        }
        #expect(throws: (any Error).self) {
            _ = try store.draftURL(
                id: UUID(),
                filename: "../../outside.wav"
            )
        }
        let unsafe = try makeDraft(
            directories: directories,
            modelID: "../outside"
        )
        #expect(throws: (any Error).self) {
            _ = try store.saveGenerated(unsafe, name: "Cobalt Wren")
        }
    }

    @Test("Recorded clones retain local metadata and reference audio")
    @MainActor
    func recordedClonePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let sessionID = UUID()
        let recordingID = UUID()
        let directory = try store.prepareDraftDirectory(id: sessionID)
        let referenceURL = directory.appending(path: "clone-reference.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: referenceURL)
        let tuning = VoiceTuning(
            preset: .expressive,
            parameters: ["temperature": 0.9]
        )
        let draft = VoiceCloneDraft(
            sessionID: sessionID,
            recordingID: recordingID,
            modelID: "chatterbox-fp16",
            language: "en-US",
            transcript: "The retained local transcript.",
            duration: 9,
            tuning: tuning,
            referenceURL: referenceURL
        )

        let saved = try store.saveRecorded(draft, name: "Velvet Finch")
        let record = try #require(store.record(id: saved.id))

        #expect(saved.origin == .recordedClone)
        #expect(record.transcript == "The retained local transcript.")
        #expect(record.tuning == tuning)
        #expect(
            FileManager.default.fileExists(
                atPath: try store.referenceURL(for: record).path
            )
        )
    }

    @Test("Drafts older than twenty-four hours are pruned")
    @MainActor
    func oldDraftCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let oldDraft = directories.voiceDrafts.appending(
            path: UUID().uuidString
        )
        try FileManager.default.createDirectory(
            at: oldDraft,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [
                .modificationDate:
                    Date.now.addingTimeInterval(-25 * 60 * 60)
            ],
            ofItemAtPath: oldDraft.path
        )

        _ = VoiceProfileStore(directories: directories)

        #expect(!FileManager.default.fileExists(atPath: oldDraft.path))
    }

    @Test("Profiles rename, sort, filter, delete, and remove drafts")
    @MainActor
    func profileCRUDAndOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let first = try store.saveGenerated(
            makeDraft(directories: directories, modelID: "model-b"),
            name: "Zulu"
        )
        let second = try store.saveGenerated(
            makeDraft(directories: directories, modelID: "model-a"),
            name: "Beta"
        )
        let third = try store.saveGenerated(
            makeDraft(directories: directories, modelID: "model-a"),
            name: "Alpha"
        )

        #expect(
            store.snapshots.map(\.id) == [third.id, second.id, first.id]
        )
        #expect(
            Set(store.records(modelID: "model-a").map(\.id))
                == [second.id, third.id]
        )

        let renamed = try store.rename(id: second.id, name: "  Gamma  ")
        #expect(renamed.displayName == "Gamma")
        #expect(store.record(id: second.id)?.displayName == "Gamma")
        #expect(throws: ServiceFailure.self) {
            _ = try store.rename(id: second.id, name: "alpha")
        }
        for invalidName in ["", "   ", String(repeating: "x", count: 51)] {
            #expect(throws: ServiceFailure.self) {
                _ = try store.rename(id: second.id, name: invalidName)
            }
        }

        let draftID = UUID()
        let draftDirectory = try store.prepareDraftDirectory(id: draftID)
        try Data([1]).write(
            to: try store.draftURL(id: draftID, filename: "sample.wav")
        )
        store.removeDraft(id: draftID)
        #expect(!FileManager.default.fileExists(atPath: draftDirectory.path))
        store.removeDraft(id: UUID())

        try store.delete(id: first.id)
        #expect(store.record(id: first.id) == nil)
        #expect(throws: ServiceFailure.self) {
            try store.delete(id: first.id)
        }
        #expect(throws: ServiceFailure.self) {
            _ = try store.rename(id: UUID(), name: "Missing")
        }
    }

    @Test("Missing and external profile sources are rejected")
    @MainActor
    func invalidProfileSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let missing = VoiceDraftCandidate(
            snapshot: VoiceCandidateSnapshot(
                id: UUID(),
                suggestedName: "Missing",
                duration: 1,
                fingerprint: []
            ),
            modelID: "qwen3_tts",
            language: nil,
            transcript: "Missing",
            tuning: VoiceTuning(),
            generationSeed: 1,
            audioURL: directories.voiceDrafts.appending(path: "missing.wav")
        )
        #expect(throws: ServiceFailure.self) {
            _ = try store.saveGenerated(missing, name: "Missing")
        }

        let outside = root.appending(path: "outside.wav")
        try Data([1]).write(to: outside)
        let clone = VoiceCloneDraft(
            sessionID: UUID(),
            recordingID: UUID(),
            modelID: "qwen3_tts",
            language: nil,
            transcript: nil,
            duration: 1,
            tuning: VoiceTuning(),
            referenceURL: outside
        )
        #expect(throws: ServiceFailure.self) {
            _ = try store.saveRecorded(clone, name: "Outside")
        }

        let valid = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Reference"
        )
        let record = try #require(store.record(id: valid.id))
        try FileManager.default.removeItem(
            at: try store.referenceURL(for: record)
        )
        #expect(throws: ServiceFailure.self) {
            _ = try store.referenceURL(for: record)
        }
    }

    @MainActor
    private func makeDraft(
        directories: AppDirectories,
        modelID: String = "omnivoice"
    ) throws -> VoiceDraftCandidate {
        let sessionID = UUID()
        let directory = directories.voiceDrafts
            .appending(path: sessionID.uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let audioURL = directory.appending(path: "candidate.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)
        let snapshot = VoiceCandidateSnapshot(
            id: UUID(),
            suggestedName: "Amber Brook",
            duration: 7,
            fingerprint: [0.2, 0.8]
        )
        return VoiceDraftCandidate(
            snapshot: snapshot,
            modelID: modelID,
            language: "en-US",
            transcript: "A calm and clearly spoken reference passage.",
            tuning: VoiceTuning(),
            generationSeed: 42,
            audioURL: audioURL
        )
    }
}
