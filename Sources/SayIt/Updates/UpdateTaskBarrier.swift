import Foundation

@MainActor
final class UpdateTaskBarrier {
    private var finished = false

    static func wait(
        for tasks: [Task<Void, Never>],
        until deadline: Date,
        clock: LifecycleClock = .system
    ) async throws {
        let barrier = UpdateTaskBarrier()
        let waiter = Task {
            for task in tasks { await task.value }
            barrier.finished = true
        }
        defer { waiter.cancel() }
        try await clock.wait(until: deadline) { barrier.finished }
    }

    typealias BarrierError = LifecycleClock.WaitError
}
