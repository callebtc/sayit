import Foundation
import SayItCore
import SayItProtocol

struct JobJournal: Codable {
    var jobs: [SpeechJob]
    var pendingJobs: [UUID: PendingSpeechJob]
    var queuedJobIDs: [UUID]
    var activeJobID: UUID?
}

@MainActor
final class JobJournalStore {
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appending(path: "Speech Jobs.json")
    }

    func load() -> JobJournal? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.sayIt.decode(JobJournal.self, from: data)
    }

    func save(_ journal: JobJournal) throws {
        let data = try JSONEncoder.sayIt.encode(journal)
        try data.write(to: fileURL, options: .atomic)
    }
}
