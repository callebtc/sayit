import Foundation
import Observation
import SayItProtocol

@MainActor
@Observable
final class HistoryStore {
    private(set) var items: [HistoryItemSnapshot] = []

    func apply(_ snapshots: [HistorySnapshot]) {
        items = snapshots.map(HistoryItemSnapshot.init)
    }

    func search(_ query: String) -> [HistoryItemSnapshot] {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(normalized)
                || $0.cleanedText.localizedStandardContains(normalized)
        }
    }
}
