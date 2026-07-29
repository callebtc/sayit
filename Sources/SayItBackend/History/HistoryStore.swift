import Foundation

import Observation
import SayItCore
import SwiftData

@MainActor
@Observable
final class HistoryStore {
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
        let item = SpeechItem(
            id: request.id,
            title: request.cleanedText.title,
            cleanedText: request.cleanedText.text,
            createdAt: request.createdAt,
            triggerSourceRawValue: request.source.rawValue,
            modelIDRawValue: request.model.id.rawValue,
            modelRevision: request.model.revision,
            voice: request.voice,
            language: request.language,
            characterCount: request.cleanedText.characterCount
        )
        context.insert(item)
        try context.save()
        try reload()
    }

    func complete(
        id: UUID,
        duration: TimeInterval,
        audioRelativePath: String,
        audioByteCount: Int64
    ) throws {
        guard let item = try item(with: id) else { return }
        item.duration = duration
        item.audioRelativePath = audioRelativePath
        item.audioByteCount = audioByteCount
        item.stateRawValue = SpeechItemState.completed.rawValue
        item.updatedAt = .now
        try context.save()
        try reload()
    }

    func markIncomplete(id: UUID, state: SpeechItemState, code: String? = nil) throws {
        guard let item = try item(with: id) else { return }
        if let relativePath = item.audioRelativePath {
            try? FileManager.default.removeItem(
                at: directories.historyAudio.appending(path: relativePath)
            )
        }
        item.audioRelativePath = nil
        item.audioByteCount = 0
        item.duration = 0
        item.stateRawValue = state.rawValue
        item.failureCode = code
        item.updatedAt = .now
        try context.save()
        try reload()
    }

    func togglePinned(id: UUID) throws {
        guard let item = try item(with: id) else { return }
        item.isPinned.toggle()
        item.updatedAt = .now
        try context.save()
        try reload()
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
        try reload()
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
        try reload()
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
        let identifiers = RetentionPlanner().identifiersToRemove(
            from: candidates,
            period: period,
            quotaBytes: quotaBytes
        )
        for id in identifiers {
            try remove(id: id)
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

    private func reload() throws {
        var descriptor = FetchDescriptor<SpeechItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        var repairedTitle = false
        items = try context.fetch(descriptor).map {
            let storedTitle = titleGenerator.title(from: $0.title)
            let title = storedTitle == SpeechTitleGenerator.fallbackTitle
                ? titleGenerator.title(from: $0.cleanedText)
                : storedTitle
            if $0.title != title {
                $0.title = title
                repairedTitle = true
            }
            return HistoryItemSnapshot(
                id: $0.id,
                title: title,
                cleanedText: $0.cleanedText,
                createdAt: $0.createdAt,
                modelID: ModelID($0.modelIDRawValue),
                voice: $0.voice,
                duration: $0.duration,
                audioRelativePath: $0.audioRelativePath,
                state: SpeechItemState(rawValue: $0.stateRawValue) ?? .failed,
                isPinned: $0.isPinned
            )
        }
        if repairedTitle {
            try context.save()
        }
    }
}
