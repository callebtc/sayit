import Foundation

public struct RetentionPlanner: Sendable {
    public init() {}

    public func identifiersToRemove(
        from candidates: [RetentionCandidate],
        period: RetentionPeriod,
        quotaBytes: Int64,
        now: Date = .now
    ) -> Set<UUID> {
        let unpinned = candidates.filter { !$0.isPinned }
        var removals: Set<UUID> = []

        if let interval = period.interval {
            let cutoff = now.addingTimeInterval(-interval)
            for candidate in unpinned where candidate.updatedAt < cutoff {
                removals.insert(candidate.id)
            }
        }

        var retainedBytes = candidates
            .filter { !removals.contains($0.id) }
            .reduce(Int64(0)) { $0 + max(0, $1.audioByteCount) }

        for candidate in unpinned.sorted(by: { $0.updatedAt < $1.updatedAt })
        where retainedBytes > quotaBytes && !removals.contains(candidate.id) {
            removals.insert(candidate.id)
            retainedBytes -= max(0, candidate.audioByteCount)
        }

        return removals
    }
}
