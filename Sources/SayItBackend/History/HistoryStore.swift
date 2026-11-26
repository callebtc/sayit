import Foundation

import Observation
import SayItCore
import SayItProtocol
import SwiftData

@MainActor
@Observable
final class HistoryStore {
    private static let maxLoadedItems = 500

    let container: ModelContainer
    private let context: ModelContext
    private let directories: AppDirectories
    private let titleGenerator = SpeechTitleGenerator()
    private(set) var items: [HistoryItemSnapshot] = []

    init(directories: AppDirectories) throws {
        self.directories = directories
        let configuration = ModelConfiguration(
            "SayItHistory",
            schema: Schema([SpeechItem.self]),
            url: directories.applicationSupport.appending(path: "History.store")
        )
        container = try ModelContainer(
            for: SpeechItem.self,
            configurations: configuration
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
        try reload()
    }

    func begin(_ request: SpeechRequest) throws {
        let title = normalizedTitle(
            title: request.cleanedText.title,
            cleanedText: request.cleanedText.text
        )
        let item = SpeechItem(
            id: request.id,
            title: title,
            cleanedText: request.cleanedText.text,
            createdAt: request.createdAt,
            triggerSourceRawValue: request.source.rawValue,
            modelIDRawValue: request.model.id.rawValue,
            modelRevision: request.model.revision,
            voice: request.voice,
            voiceModeRawValue: request.voiceMode.rawValue,
            voiceProfileID: request.voiceProfileID,
            voiceProfileName: request.voiceProfileName,
            language: request.language,
            characterCount: request.cleanedText.characterCount
        )
        context.insert(item)
        try context.save()
        let snapshot = makeSnapshot(from: item, title: title)
        if items.first.map({ snapshot.createdAt >= $0.createdAt }) ?? true {
            items.insert(snapshot, at: 0)
        } else {
            let insertionIndex = items.firstIndex { $0.createdAt < snapshot.createdAt }
                ?? items.endIndex
            items.insert(snapshot, at: insertionIndex)
        }
        if items.count > Self.maxLoadedItems {
            items.removeLast(items.count - Self.maxLoadedItems)
        }
    }

    func complete(
        id: UUID,
        duration: TimeInterval,
        audioRelativePath: String,
        audioByteCount: Int64,
        spokenChunks: [PlaybackTextChunk] = []
    ) throws {
        guard let item = try item(with: id) else { return }
        item.playbackTimingData = try JSONEncoder().encode(spokenChunks)
        item.duration = duration
        item.audioRelativePath = audioRelativePath
        item.audioByteCount = audioByteCount
        item.stateRawValue = SpeechItemState.completed.rawValue
        item.updatedAt = .now
        try context.save()
        updateCachedItem(item)
    }

    func playbackTiming(id: UUID) throws -> [PlaybackTextChunk] {
        guard let item = try item(with: id), let data = item.playbackTimingData,
              let chunks = try? JSONDecoder().decode([PlaybackTextChunk].self, from: data)
        else { return [] }
        // Missing/corrupt timing must never prevent replaying a valid recording.
        var textEnd = 0
        var audioStart: TimeInterval = 0
        for chunk in chunks {
            guard chunk.textStart >= textEnd, chunk.textEnd > chunk.textStart,
                  chunk.textEnd <= item.characterCount,
                  chunk.audioStart.isFinite, chunk.audioStart >= audioStart,
                  chunk.audioStart <= item.duration,
                  let end = chunk.audioEnd, end.isFinite,
                  end >= chunk.audioStart, end <= item.duration else { return [] }
            textEnd = chunk.textEnd
            audioStart = chunk.audioStart
        }
        return chunks
    }

    func markIncomplete(id: UUID, state: SpeechItemState, code: String? = nil) throws {
        guard let item = try item(with: id) else { return }
        if let relativePath = item.audioRelativePath {
            try? FileManager.default.removeItem(
                at: directories.historyAudio.appending(path: relativePath)
            )
        }
        item.playbackTimingData = nil
        item.audioRelativePath = nil
        item.audioByteCount = 0
        item.duration = 0
        item.stateRawValue = state.rawValue
        item.failureCode = code
        item.updatedAt = .now
        try context.save()
        updateCachedItem(item)
    }

    func togglePinned(id: UUID) throws {
        guard let item = try item(with: id) else { return }
        item.isPinned.toggle()
        item.updatedAt = .now
        try context.save()
        updateCachedItem(item)
    }

    func remove(id: UUID) throws {
        guard let item = try item(with: id) else { return }
        if let relativePath = item.audioRelativePath {
            try? FileManager.default.removeItem(
                at: directories.historyAudio.appending(path: relativePath)
            )
        }
        context.delete(item)
        try context.save()
        if items.count < Self.maxLoadedItems {
            items.removeAll { $0.id == id }
        } else {
            try reload()
        }
    }

    func removeAll() throws {
        let descriptor = FetchDescriptor<SpeechItem>()
        for item in try context.fetch(descriptor) {
            if let relativePath = item.audioRelativePath {
                try? FileManager.default.removeItem(
                    at: directories.historyAudio.appending(path: relativePath)
                )
            }
            context.delete(item)
        }
        try context.save()
        items = []
    }

    func enforceRetention(period: RetentionPeriod, quotaBytes: Int64) throws {
        let descriptor = FetchDescriptor<SpeechItem>()
        let stored = try context.fetch(descriptor)
        let candidates = stored.map {
            RetentionCandidate(
                id: $0.id,
                updatedAt: $0.updatedAt,
                audioByteCount: $0.audioByteCount,
                isPinned: $0.isPinned
            )
        }
        let identifiers = Set(
            RetentionPlanner().identifiersToRemove(
                from: candidates,
                period: period,
                quotaBytes: quotaBytes
            )
        )
        guard !identifiers.isEmpty else { return }
        for item in stored where identifiers.contains(item.id) {
            if let relativePath = item.audioRelativePath {
                try? FileManager.default.removeItem(
                    at: directories.historyAudio.appending(path: relativePath)
                )
            }
            context.delete(item)
        }
        try context.save()
        if items.count < Self.maxLoadedItems {
            items.removeAll { identifiers.contains($0.id) }
        } else {
            try reload()
        }
    }

    func audioURL(for snapshot: HistoryItemSnapshot) -> URL? {
        snapshot.audioRelativePath.map { directories.historyAudio.appending(path: $0) }
    }

    func search(_ text: String) -> [HistoryItemSnapshot] {
        guard !text.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(text)
                || $0.cleanedText.localizedStandardContains(text)
        }
    }

    private func item(with id: UUID) throws -> SpeechItem? {
        var descriptor = FetchDescriptor<SpeechItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func normalizedTitle(title: String, cleanedText: String) -> String {
        let storedTitle = titleGenerator.title(from: title)
        return storedTitle == SpeechTitleGenerator.fallbackTitle
            ? titleGenerator.title(from: cleanedText)
            : storedTitle
    }

    private func makeSnapshot(from item: SpeechItem, title: String) -> HistoryItemSnapshot {
        HistoryItemSnapshot(
            id: item.id,
            title: title,
            cleanedText: item.cleanedText,
            createdAt: item.createdAt,
            modelID: ModelID(item.modelIDRawValue),
            voice: item.voice,
            voiceMode: VoiceSynthesisMode(
                rawValue: item.voiceModeRawValue ?? ""
            ) ?? .standard,
            voiceProfileID: item.voiceProfileID,
            voiceProfileName: item.voiceProfileName,
            language: item.language,
            duration: item.duration,
            audioRelativePath: item.audioRelativePath,
            state: SpeechItemState(rawValue: item.stateRawValue) ?? .failed,
            isPinned: item.isPinned
        )
    }

    private func updateCachedItem(_ item: SpeechItem) {
        let title = normalizedTitle(title: item.title, cleanedText: item.cleanedText)
        let snapshot = makeSnapshot(from: item, title: title)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = snapshot
        }
    }

    private func reload() throws {
        var descriptor = FetchDescriptor<SpeechItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maxLoadedItems
        var repairedTitle = false
        items = try context.fetch(descriptor).map {
            let title = normalizedTitle(title: $0.title, cleanedText: $0.cleanedText)
            if $0.title != title {
                $0.title = title
                repairedTitle = true
            }
            return makeSnapshot(from: $0, title: title)
        }
        if repairedTitle {
            try context.save()
        }
    }
}
