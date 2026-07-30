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
