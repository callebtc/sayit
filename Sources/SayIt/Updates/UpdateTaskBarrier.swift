import Foundation

@MainActor
final class UpdateTaskBarrier {
    private var finished = false

    static func wait(for tasks: [Task<Void, Never>], until deadline: Date) async throws {
        let barrier = UpdateTaskBarrier()
        let waiter = Task {
            for task in tasks { await task.value }
            barrier.finished = true
        }
        defer { waiter.cancel() }
        while !barrier.finished {
            try Task.checkCancellation()
            guard Date.now < deadline else { throw BarrierError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    enum BarrierError: Error { case timedOut }
}
