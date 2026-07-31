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
            store.snapshots.map(\.id) == [second.id, third.id, first.id]
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

    @Test("Reordering persists and rejects mismatched voice lists")
    @MainActor
    func profileReordering() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let first = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Amber Brook"
        )
        let second = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Silver Lark"
        )
        let third = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Velvet Finch"
        )
        let other = try store.saveGenerated(
            makeDraft(directories: directories, modelID: "other-model"),
            name: "Cobalt Wren"
        )

        try store.reorder(
            modelID: "omnivoice",
            orderedIDs: [third.id, first.id, second.id]
        )
        #expect(
            store.snapshots.map(\.id)
                == [third.id, first.id, second.id, other.id]
        )
        #expect(store.record(id: first.id)?.sortOrder == 1)

        let reloaded = VoiceProfileStore(directories: directories)
        #expect(
            reloaded.snapshots.map(\.id)
                == [third.id, first.id, second.id, other.id]
        )

        #expect(throws: ServiceFailure.self) {
            try store.reorder(modelID: "omnivoice", orderedIDs: [first.id])
        }
        #expect(throws: ServiceFailure.self) {
            try store.reorder(
                modelID: "omnivoice",
                orderedIDs: [first.id, second.id, other.id]
            )
        }
        #expect(throws: ServiceFailure.self) {
            try store.reorder(modelID: "../escape", orderedIDs: [])
        }
        #expect(
            store.snapshots.map(\.id)
                == [third.id, first.id, second.id, other.id]
        )
    }

    @Test("Profiles saved before sort order existed decode with defaults")
    @MainActor
    func legacyProfilesDecodeWithoutSortOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let saved = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Amber Brook"
        )
        let metadata = directories.voiceProfiles
            .appending(path: "omnivoice")
            .appending(path: saved.id.uuidString)
            .appending(path: "profile.json")
        var json = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: metadata)
            ) as? [String: Any]
        )
        json["sortOrder"] = nil
        try JSONSerialization.data(withJSONObject: json)
            .write(to: metadata)

        let reloaded = VoiceProfileStore(directories: directories)
        let record = try #require(reloaded.record(id: saved.id))
        #expect(record.sortOrder == 0)
        #expect(reloaded.snapshots.map(\.id) == [saved.id])
    }

    @Test("Tuning updates persist and duplicated profiles stay independent")
    @MainActor
    func tuningUpdateAndDuplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItVoiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try AppDirectories.testing(root: root)
        let store = VoiceProfileStore(directories: directories)
        let saved = try store.saveGenerated(
            makeDraft(directories: directories),
            name: "Amber Brook"
        )
        let tuning = VoiceTuning(
            preset: .expressive,
            parameters: ["temperature": 0.85]
        )

        let updated = try store.updateTuning(id: saved.id, tuning: tuning)
        #expect(updated.tuning == tuning)
        #expect(updated.updatedAt >= saved.updatedAt)

        let copyTuning = VoiceTuning(
            preset: .faithful,
            parameters: ["temperature": 0.45]
        )
        let copy = try store.duplicate(
            id: saved.id,
            name: "Amber Copy",
            tuning: copyTuning
        )
        #expect(copy.id != saved.id)
        #expect(copy.tuning == copyTuning)
        let originalRecord = try #require(store.record(id: saved.id))
        let copyRecord = try #require(store.record(id: copy.id))
        let originalReference = try store.referenceURL(for: originalRecord)
        let copyReference = try store.referenceURL(for: copyRecord)
        #expect(originalReference != copyReference)
        #expect(
            FileManager.default.fileExists(atPath: copyReference.path)
        )

        let reloaded = VoiceProfileStore(directories: directories)
        #expect(reloaded.record(id: saved.id)?.tuning == tuning)
        #expect(reloaded.record(id: copy.id)?.displayName == "Amber Copy")

        try store.delete(id: copy.id)
        #expect(store.record(id: saved.id) != nil)
        #expect(
            FileManager.default.fileExists(atPath: originalReference.path)
        )

        #expect(throws: ServiceFailure.self) {
            _ = try store.updateTuning(id: UUID(), tuning: tuning)
        }
        #expect(throws: ServiceFailure.self) {
            _ = try store.duplicate(
                id: saved.id,
                name: "amber brook",
                tuning: tuning
            )
        }
        #expect(throws: ServiceFailure.self) {
            _ = try store.updateTuning(
                id: saved.id,
                tuning: VoiceTuning(parameters: ["temperature": .nan])
            )
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
