import Foundation

/// Keep capture and acknowledgement in order, including rapid shortcut presses.
@MainActor
final class SelectionShortcutQueue {
    private var operations: [@MainActor () async -> Void] = []
    private(set) var task: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        operations.append(operation)
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while !operations.isEmpty, !Task.isCancelled {
                let next = operations.removeFirst()
                await next()
            }
        }
    }

    func cancel() {
        operations.removeAll()
        task?.cancel()
    }
}
