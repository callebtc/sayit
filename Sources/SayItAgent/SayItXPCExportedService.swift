import Foundation
import SayItBackend
import SayItProtocol
import SayItXPC

final class SayItXPCExportedService: NSObject, SayItXPCProtocol, @unchecked Sendable {
    private let backend: SayItBackendService
    private let taskLock = NSLock()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var isInvalidated = false

    init(backend: SayItBackendService) {
        self.backend = backend
    }

    func perform(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        let taskID = UUID()
        let task = Task { [weak self, backend] in
            defer {
                self?.removeTask(id: taskID)
            }
            let response: ServiceResponse
            do {
                let request = try SayItWireCodec.decode(
                    ServiceRequest.self,
                    from: requestData
                )
                response = await backend.handle(request)
            } catch {
                response = .failure(
                    ServiceFailure(
                        code: "protocol.invalid_request",
                        message: "The service request could not be decoded."
                    )
                )
            }
            let data = (try? SayItWireCodec.encode(response)) ?? Data()
            reply(data)
        }
        let shouldCancel = taskLock.withLock { () -> Bool in
            guard !isInvalidated else { return true }
            activeTasks[taskID] = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancelAllRequests(invalidate: Bool = false) {
        let tasksToCancel = taskLock.withLock { () -> [Task<Void, Never>] in
            if invalidate {
                isInvalidated = true
            }
            let tasks = Array(activeTasks.values)
            activeTasks.removeAll(keepingCapacity: false)
            return tasks
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }

    private func removeTask(id: UUID) {
        taskLock.withLock {
            activeTasks[id] = nil
        }
    }
}
