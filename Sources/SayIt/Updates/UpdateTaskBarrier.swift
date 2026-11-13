import Foundation

@MainActor
final class UpdateTaskBarrier {
    private var finished = false

    static func wait(
        for tasks: [Task<Void, Never>],
        until deadline: Date,
        now: () -> Date = { Date.now },
        sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) async throws {
        let barrier = UpdateTaskBarrier()
        let waiter = Task {
            for task in tasks { await task.value }
            barrier.finished = true
        }
        defer { waiter.cancel() }
        while !barrier.finished {
            try Task.checkCancellation()
            guard now() < deadline else { throw BarrierError.timedOut }
            try await sleep(0.05)
        }
        guard now() <= deadline else { throw BarrierError.timedOut }
    }

    enum BarrierError: Error { case timedOut }
}
