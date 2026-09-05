import Foundation

@MainActor
final class ServiceEventHub {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var latestRevision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    var waiterCount: Int {
        waiters.count
    }

    init(
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func publish(_ revision: UInt64) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        resumeAllWaiters()
    }

    func wait(
        after sequence: UInt64,
        currentRevision: UInt64,
        timeout: Duration
    ) async throws {
        guard currentRevision == sequence,
              latestRevision <= sequence else { return }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard currentRevision == sequence,
                      latestRevision <= sequence else {
                    continuation.resume()
                    return
                }

                waiters[waiterID] = continuation
                let sleep = self.sleep
                timeoutTasks[waiterID] = Task { [weak self] in
                    do {
                        try await sleep(timeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.failWaiter(waiterID, error: error)
                        return
                    }
                    self?.resumeWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func failWaiter(_ id: UUID, error: any Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func resumeAllWaiters() {
        let continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}
