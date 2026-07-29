import Foundation
import Testing
@testable import SayItCore

@Suite("History retention")
struct RetentionPlannerTests {
    @Test("Age and quota remove oldest unpinned audio")
    func removesOldUnpinnedItems() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let pinned = RetentionCandidate(
            id: UUID(),
            updatedAt: now.addingTimeInterval(-100 * 24 * 60 * 60),
            audioByteCount: 600,
            isPinned: true
        )
        let old = RetentionCandidate(
            id: UUID(),
            updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
            audioByteCount: 400,
            isPinned: false
        )
        let recent = RetentionCandidate(
            id: UUID(),
            updatedAt: now,
            audioByteCount: 500,
            isPinned: false
        )

        let removals = RetentionPlanner().identifiersToRemove(
            from: [pinned, old, recent],
            period: .thirtyDays,
            quotaBytes: 1_100,
            now: now
        )

        #expect(removals.contains(old.id))
        #expect(!removals.contains(pinned.id))
        #expect(!removals.contains(recent.id))
    }
}
