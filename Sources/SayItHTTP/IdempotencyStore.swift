import Foundation
import SayItProtocol

actor IdempotencyStore {
    private var entries: [String: IdempotencyEntry] = [:]

    func job(tokenID: UUID, key: String) -> SpeechJob? {
        removeExpiredEntries()
        return entries[storageKey(tokenID: tokenID, key: key)]?.job
    }

    func store(_ job: SpeechJob, tokenID: UUID, key: String) {
        removeExpiredEntries()
        entries[storageKey(tokenID: tokenID, key: key)] = IdempotencyEntry(
            expiresAt: Date.now.addingTimeInterval(24 * 60 * 60),
            job: job
        )
    }

    private func storageKey(tokenID: UUID, key: String) -> String {
        "\(tokenID.uuidString):\(key)"
    }

    private func removeExpiredEntries() {
        entries = entries.filter { $0.value.expiresAt > .now }
    }
}
