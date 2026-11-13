import Foundation

@MainActor
struct LifecycleClock {
    var now: () -> Date
    var sleep: (TimeInterval) async throws -> Void

    static let system = LifecycleClock(
        now: { Date.now },
        sleep: { try await Task.sleep(for: .seconds($0)) }
    )

    /// Work ownership stays with the caller; both lifecycle drains use the same
    /// cancellation, deadline boundary and waiting cadence.
    func wait(until deadline: Date, isFinished: () -> Bool) async throws {
        while !isFinished() {
            try Task.checkCancellation()
            guard now() < deadline else { throw WaitError.timedOut }
            try await sleep(0.05)
        }
        guard now() <= deadline else { throw WaitError.timedOut }
    }

    enum WaitError: Error { case timedOut }
}
