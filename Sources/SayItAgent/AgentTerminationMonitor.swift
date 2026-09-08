import Darwin
import Foundation
import SayItCore

/// launchd sends SIGTERM on bootout. Finish backend persistence before exiting.
@MainActor
final class AgentTerminationMonitor {
    private var requested = false
    private let source: any DispatchSourceSignal
    private var continuation: CheckedContinuation<Void, Never>?
    private var parentMonitor: Task<Void, Never>?

    init() {
        signal(SIGTERM, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.requestTermination() }
        }
        source.resume()
    }

    func wait(parentPID: pid_t?) async {
        guard !requested else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if let parentPID {
                    parentMonitor = Task { [weak self] in
                        while !Task.isCancelled {
                            if !ParentProcessFile.isAlive(parentPID) {
                                self?.requestTermination()
                                return
                            }
                            do {
                                try await Task.sleep(for: .seconds(2))
                            } catch { return }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.requestTermination() }
        }
    }

    private func requestTermination() {
        requested = true
        parentMonitor?.cancel()
        parentMonitor = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
