import Foundation
import SayItCore
import SayItProtocol

@MainActor
final class VoiceProfileStore {
    private let directories: AppDirectories
    private var recordsByID: [UUID: VoiceProfileRecord] = [:]

    init(directories: AppDirectories) {
        self.directories = directories
        reload()
        pruneDrafts()
    }

    var snapshots: [VoiceProfileSnapshot] {
        recordsByID.values
            .map(\.snapshot)
            .sorted {
                if $0.modelID == $1.modelID {
                    $0.displayName.localizedStandardCompare($1.displayName)
                        == .orderedAscending
                } else {
                    $0.modelID < $1.modelID
                }
            }
    }

    func record(id: UUID) -> VoiceProfileRecord? {
        recordsByID[id]
    }

    func records(modelID: String) -> [VoiceProfileRecord] {
        recordsByID.values.filter { $0.modelID == modelID }
    }

    func referenceURL(for record: VoiceProfileRecord) throws -> URL {
        let url = profileDirectory(modelID: record.modelID, id: record.id)
            .appending(path: record.referenceFilename)
        guard isContained(url, by: directories.voiceProfiles),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceFailure(
                code: "voice.reference_missing",
                message: "The saved voice reference is missing."
            )
        }
        return url
    }

    func draftURL(
        id: UUID,
        filename: String = "reference.wav"
    ) throws -> URL {
        guard !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains("/") else {
            throw ServiceFailure(
                code: "voice.invalid_draft",
                message: "The voice draft filename is invalid."
            )
        }
        let url = directories.voiceDrafts
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: filename)
        guard isContained(url, by: directories.voiceDrafts) else {
            throw ServiceFailure(
                code: "voice.invalid_draft",
                message: "The voice draft location is invalid."
            )
        }
        return url
    }

    func prepareDraftDirectory(id: UUID) throws -> URL {
        let directory = directories.voiceDrafts.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        guard isContained(directory, by: directories.voiceDrafts) else {
            throw ServiceFailure(
                code: "voice.invalid_draft",
                message: "The voice draft location is invalid."
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func saveGenerated(
        _ draft: VoiceDraftCandidate,
        name: String
    ) throws -> VoiceProfileSnapshot {
        guard isSafeModelID(draft.modelID),
              isContained(draft.audioURL, by: directories.voiceDrafts),
              FileManager.default.fileExists(atPath: draft.audioURL.path) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile source is invalid."
            )
        }
        let validatedName = try validated(
            name: name,
            modelID: draft.modelID,
            excluding: nil
        )
        let id = UUID()
        let directory = profileDirectory(modelID: draft.modelID, id: id)
        guard isContained(directory, by: directories.voiceProfiles) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile location is invalid."
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory.appending(path: "reference.wav")
        do {
            try FileManager.default.copyItem(
                at: draft.audioURL,
                to: destination
            )
            let now = Date.now
            let record = VoiceProfileRecord(
                schemaVersion: 1,
                id: id,
                modelID: draft.modelID,
                displayName: validatedName,
                origin: .generated,
                language: draft.language,
                transcript: draft.transcript,
                duration: draft.snapshot.duration,
                referenceFilename: "reference.wav",
                createdAt: now,
                updatedAt: now,
                tuning: draft.tuning,
                generationSeed: draft.generationSeed
            )
            try write(record, to: directory)
            recordsByID[id] = record
            return record.snapshot
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func saveRecorded(
        _ draft: VoiceCloneDraft,
        name: String
    ) throws -> VoiceProfileSnapshot {
        guard isSafeModelID(draft.modelID),
              isContained(draft.referenceURL, by: directories.voiceDrafts),
              FileManager.default.fileExists(
                  atPath: draft.referenceURL.path
              ) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile source is invalid."
            )
        }
        let validatedName = try validated(
            name: name,
            modelID: draft.modelID,
            excluding: nil
        )
        let id = UUID()
        let directory = profileDirectory(modelID: draft.modelID, id: id)
        guard isContained(directory, by: directories.voiceProfiles) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile location is invalid."
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory.appending(path: "reference.wav")
        do {
            try FileManager.default.copyItem(
                at: draft.referenceURL,
                to: destination
            )
            let now = Date.now
            let record = VoiceProfileRecord(
                schemaVersion: 1,
                id: id,
                modelID: draft.modelID,
                displayName: validatedName,
                origin: .recordedClone,
                language: draft.language,
                transcript: draft.transcript,
                duration: draft.duration,
                referenceFilename: "reference.wav",
                createdAt: now,
                updatedAt: now,
                tuning: draft.tuning,
                generationSeed: nil
            )
            try write(record, to: directory)
            recordsByID[id] = record
            return record.snapshot
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func rename(id: UUID, name: String) throws -> VoiceProfileSnapshot {
        guard var record = recordsByID[id] else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        record.displayName = try validated(
            name: name,
            modelID: record.modelID,
            excluding: id
        )
        record.updatedAt = .now
        try write(
            record,
            to: profileDirectory(modelID: record.modelID, id: id)
        )
        recordsByID[id] = record
        return record.snapshot
    }

    func updateTuning(
        id: UUID,
        tuning: VoiceTuning
    ) throws -> VoiceProfileSnapshot {
        guard tuning.parameters.values.allSatisfy(\.isFinite),
              var record = recordsByID[id] else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        record.tuning = tuning
        record.updatedAt = .now
        try write(
            record,
            to: profileDirectory(modelID: record.modelID, id: id)
        )
        recordsByID[id] = record
        return record.snapshot
    }

    func duplicate(
        id: UUID,
        name: String,
        tuning: VoiceTuning
    ) throws -> VoiceProfileSnapshot {
        guard tuning.parameters.values.allSatisfy(\.isFinite),
              let source = recordsByID[id] else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        let validatedName = try validated(
            name: name,
            modelID: source.modelID,
            excluding: nil
        )
        let newID = UUID()
        let sourceDirectory = profileDirectory(
            modelID: source.modelID,
            id: source.id
        )
        let directory = profileDirectory(modelID: source.modelID, id: newID)
        guard isContained(directory, by: directories.voiceProfiles) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile location is invalid."
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(
                at: sourceDirectory.appending(path: source.referenceFilename),
                to: directory.appending(path: "reference.wav")
            )
            let now = Date.now
            let record = VoiceProfileRecord(
                schemaVersion: 1,
                id: newID,
                modelID: source.modelID,
                displayName: validatedName,
                origin: source.origin,
                language: source.language,
                transcript: source.transcript,
                duration: source.duration,
                referenceFilename: "reference.wav",
                createdAt: now,
                updatedAt: now,
                tuning: tuning,
                generationSeed: source.generationSeed
            )
            try write(record, to: directory)
            recordsByID[newID] = record
            return record.snapshot
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func delete(id: UUID) throws {
        guard let record = recordsByID[id] else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        let directory = profileDirectory(modelID: record.modelID, id: id)
        guard isContained(directory, by: directories.voiceProfiles) else {
            throw ServiceFailure(
                code: "voice.invalid_profile",
                message: "The voice profile location is invalid."
            )
        }
        try FileManager.default.removeItem(at: directory)
        recordsByID[id] = nil
    }

    func removeDraft(id: UUID) {
        let directory = directories.voiceDrafts.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        guard isContained(directory, by: directories.voiceDrafts) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func validated(
        name: String,
        modelID: String,
        excluding id: UUID?
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...50).contains(trimmed.count) else {
            throw ServiceFailure(
                code: "voice.invalid_name",
                message: "Voice names must contain 1 to 50 characters."
            )
        }
        let duplicate = recordsByID.values.contains {
            $0.id != id
                && $0.modelID == modelID
                && $0.displayName.compare(
                    trimmed,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }
        guard !duplicate else {
            throw ServiceFailure(
                code: "voice.duplicate_name",
                message: "Choose a different name for this model."
            )
        }
        return trimmed
    }

    private func reload() {
        recordsByID.removeAll()
        let manager = FileManager.default
        guard let modelDirectories = try? manager.contentsOfDirectory(
            at: directories.voiceProfiles,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for modelDirectory in modelDirectories {
            guard let profileDirectories = try? manager.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for directory in profileDirectories {
                let metadata = directory.appending(path: "profile.json")
                let reference = directory.appending(path: "reference.wav")
                guard isContained(metadata, by: directories.voiceProfiles),
                      isContained(reference, by: directory),
                      manager.fileExists(atPath: reference.path),
                      let data = try? Data(contentsOf: metadata),
                      let record = try? JSONDecoder.sayIt.decode(
                          VoiceProfileRecord.self,
                          from: data
                      ),
                      isValid(record),
                      modelDirectory.lastPathComponent == record.modelID,
                      directory.lastPathComponent == record.id.uuidString else {
                    continue
                }
                recordsByID[record.id] = record
            }
        }
    }

    private func write(_ record: VoiceProfileRecord, to directory: URL) throws {
        let data = try JSONEncoder.sayIt.encode(record)
        try data.write(
            to: directory.appending(path: "profile.json"),
            options: .atomic
        )
    }

    private func profileDirectory(modelID: String, id: UUID) -> URL {
        let safeModelID = isSafeModelID(modelID) ? modelID : "invalid-model"
        return directories.voiceProfiles
            .appending(path: safeModelID, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func isSafeModelID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            ).contains($0)
        }
    }

    private func isValid(_ record: VoiceProfileRecord) -> Bool {
        let trimmedName = record.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return record.schemaVersion == 1
            && isSafeModelID(record.modelID)
            && record.displayName == trimmedName
            && (1...50).contains(trimmedName.count)
            && record.duration.isFinite
            && record.duration > 0
            && record.referenceFilename == "reference.wav"
            && record.tuning.parameters.values.allSatisfy(\.isFinite)
    }

    private func isContained(_ child: URL, by parent: URL) -> Bool {
        let parentPath = parent.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath()
            .standardizedFileURL.path
        return childPath == parentPath
            || childPath.hasPrefix(parentPath + "/")
    }

    private func pruneDrafts() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directories.voiceDrafts,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true {
                try? manager.removeItem(at: url)
            }
        }
    }
}
