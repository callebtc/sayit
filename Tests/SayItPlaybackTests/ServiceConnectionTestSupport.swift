import Foundation
import SayItProtocol
import SayItXPC
import Testing
@testable import SayIt

@MainActor
final class ScriptedConnectionTransport: ServiceConnectionTransport {
    private(set) var requests: [ServiceCommand] = []
    private(set) var invalidations = 0
    var heldRequests: Set<Int> = []
    private var pending: [Int: CheckedContinuation<ServiceResponse, any Error>] = [:]

    func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        let index = requests.count
        requests.append(command)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel(index) }
        }
    }

    func invalidate() async {
        invalidations += 1
        for index in Array(pending.keys) { cancel(index) }
    }

    private func cancel(_ index: Int) {
        guard !heldRequests.contains(index) else { return }
        pending.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }

    func reply(_ index: Int, _ response: ServiceResponse) {
        guard let continuation = pending.removeValue(forKey: index) else {
            Issue.record("No pending request at index \(index)")
            return
        }
        continuation.resume(returning: response)
    }

    func fail(_ index: Int, _ error: any Error = SayItXPCClientError.connectionUnavailable) {
        guard let continuation = pending.removeValue(forKey: index) else {
            Issue.record("No pending request at index \(index)")
            return
        }
        continuation.resume(throwing: error)
    }
}

@MainActor
final class ScriptedConnectionRegistration: ServiceConnectionRegistration {
    var isUserDisabled = false
    var isWorking = false
    var requiresApproval = false
    var errorMessage: String?
    private(set) var effects: [String] = []
    var holdsRestart = false
    var holdsEnsure = false
    private var restartContinuation: CheckedContinuation<Void, Never>?
    private var ensureContinuation: CheckedContinuation<Void, Never>?

    func setUserDisabled(_ disabled: Bool) { isUserDisabled = disabled }
    func refresh() {}
    func ensureRunning() async {
        effects.append("ensure")
        if holdsEnsure {
            await withCheckedContinuation { ensureContinuation = $0 }
        }
    }
    func enable() async { isUserDisabled = false; effects.append("enable") }
    func disable() async { isUserDisabled = true; effects.append("disable") }
    func restart() async {
        effects.append("restart")
        if holdsRestart {
            await withCheckedContinuation { restartContinuation = $0 }
        }
    }

    func releaseRestart() {
        holdsRestart = false
        restartContinuation?.resume()
        restartContinuation = nil
    }

    func releaseEnsure() {
        holdsEnsure = false
        ensureContinuation?.resume()
        ensureContinuation = nil
    }

    var restartCount: Int { effects.filter { $0 == "restart" }.count }
}

@MainActor
final class ScriptedConnectionClock {
    private(set) var date = Date(timeIntervalSince1970: 0)
    private(set) var sleeps: [TimeInterval] = []
    private struct Sleep {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var pending: [UUID: Sleep] = [:]

    var adapter: LifecycleClock {
        LifecycleClock(now: { self.date }, sleep: { try await self.sleep($0) })
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        sleeps.append(seconds)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Sleep(deadline: date.addingTimeInterval(seconds), continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(_ seconds: TimeInterval) {
        date.addTimeInterval(seconds)
        for (id, sleep) in pending where sleep.deadline <= date {
            pending.removeValue(forKey: id)?.continuation.resume()
        }
    }
}

@MainActor
final class ConnectionFixture {
    let transport = ScriptedConnectionTransport()
    let registration = ScriptedConnectionRegistration()
    let clock = ScriptedConnectionClock()
    let connection: ServiceConnection
    private(set) var outputs: [ServiceConnection.Output] = []
    var snapshots: [ServiceSnapshot] {
        outputs.compactMap { if case .snapshot(let value) = $0 { value } else { nil } }
    }

    init() {
        connection = ServiceConnection(
            transport: transport, registration: registration,
            applicationVersion: "1.0", clock: clock.adapter
        )
        connection.onOutput = { [weak self] in self?.outputs.append($0) }
    }

    func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Scripted operation did not reach its gate", sourceLocation: sourceLocation)
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func advanceUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<400 {
            await settle()
            if condition() { return }
            clock.advance(0.1)
        }
        Issue.record("Scripted operation did not reach its timed gate", sourceLocation: sourceLocation)
    }

    func advancing<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        var result: Result<Value, any Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
        }
        for _ in 0..<2_000 {
            if let result { await task.value; return try result.get() }
            await settle()
            clock.advance(0.05)
        }
        task.cancel()
        await task.value
        throw TestError.didNotFinish
    }

    enum TestError: Error { case didNotFinish }
}

func connectionSnapshot(
    revision: UInt64,
    version: String = "1.0",
    protocolVersion: Int = SayItProtocolVersion.current,
    playback: PlaybackSnapshot = PlaybackSnapshot(),
    ancillaryRevision: UInt64 = 0
) -> ServiceSnapshot {
    ServiceSnapshot(
        protocolVersion: protocolVersion, serviceVersion: version, revision: revision,
        statusText: "Ready", lastError: nil, activeJob: nil, queuedJobs: [],
        playback: playback, download: nil, installedModelIDs: [],
        settings: BackendSettingsSnapshot(), modelsRevision: ancillaryRevision,
        historyRevision: ancillaryRevision, diagnosticsRevision: ancillaryRevision,
        voicesRevision: ancillaryRevision
    )
}
