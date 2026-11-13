import Foundation
import SayItProtocol
import SayItXPC

/// Owns the relationship with the agent. Only accepted snapshots cross into app
/// projections; resetting freshness and closing the gate never require an await.
@MainActor
final class ServiceConnection {
    enum Output {
        case state(ServiceConnectionState, statusText: String?)
        case reset(transportFailure: Bool)
        case snapshot(ServiceSnapshot)
    }

    var onOutput: (Output) -> Void = { _ in }
    private(set) var state: ServiceConnectionState = .connecting

    private enum Lifecycle { case idle, running, suspended, stopped }
    private struct Work {
        let cancel: () -> Void
        let join: () async -> Void
    }
    private struct Completion: Sendable {
        let result: Result<ServiceResponse, any Error>
        let epoch: UInt64
        let cursor: UInt64?
        let checksCursor: Bool
    }

    private let transport: any ServiceConnectionTransport
    private let registration: any ServiceConnectionRegistration
    private let clock: LifecycleClock
    private let applicationVersion: String
    private var lifecycle = Lifecycle.idle
    private var epoch: UInt64 = 0
    private var cursor: UInt64?
    private var automaticAttempts = 0
    private var retryDelay: TimeInterval = 0.25
    private var isPlaybackSurfaceVisible = false
    private var enabledIntent: Bool?
    private var enabledChangeEpoch: UInt64?
    private var work: [UUID: Work] = [:]
    private var pollTask: Task<Void, any Error>?
    private var registrationTask: Task<Void, any Error>?
    private var invalidationTask: Task<Void, any Error>?

    init(
        transport: any ServiceConnectionTransport,
        registration: any ServiceConnectionRegistration,
        applicationVersion: String,
        clock: LifecycleClock = .system
    ) {
        self.transport = transport
        self.registration = registration
        self.applicationVersion = applicationVersion
        self.clock = clock
    }

    func start() async {
        guard lifecycle != .stopped, lifecycle != .running else { return }
        let requestedEpoch = epoch
        // A timed-out suspension retains its work. Never reopen the gate until
        // a canceled registration (which may ignore cancellation) has returned.
        await joinWork()
        guard epoch == requestedEpoch, lifecycle != .stopped,
              !Task.isCancelled else { return }
        lifecycle = .running
        enabledChangeEpoch = nil
        reset()
        let startedEpoch = epoch
        publish(isEnabled ? .connecting : .disabled, text: nil)
        let task = own { [self] in
            defer { registrationTask = nil }
            if let enabledIntent {
                if enabledIntent { await registration.enable() }
                else { await registration.disable() }
                try check(startedEpoch, requiresEnabled: false)
                self.enabledIntent = nil
            } else if isEnabled {
                await registration.ensureRunning()
                try check(startedEpoch)
            }
        }
        registrationTask = task
        _ = await task.result
        guard lifecycle == .running, epoch == startedEpoch else { return }
        startPolling()
    }

    /// Commands are forwarded once. Recovery only retries synchronization.
    func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try Task.checkCancellation()
        guard canSend else { throw CancellationError() }
        let requestedEpoch = epoch
        let requestedCursor = cursor
        let isStateRequest: Bool
        switch command {
        case .snapshot, .events, .waitForEvents: isStateRequest = true
        default: isStateRequest = false
        }
        let task = own { [self] in
            do {
                try check(requestedEpoch)
                let response = try await transport.send(command)
                try check(requestedEpoch, cursor: requestedCursor, checksCursor: isStateRequest)
                if isStateRequest {
                    try accept(response, for: command)
                }
                return Completion(
                    result: .success(response), epoch: epoch, cursor: cursor,
                    checksCursor: isStateRequest
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try check(requestedEpoch, cursor: requestedCursor, checksCursor: isStateRequest)
                // A failure begun before a fresh snapshot cannot retire the
                // connection whose health that newer snapshot established.
                if error is SayItXPCClientError, cursor != requestedCursor {
                    throw CancellationError()
                }
                if error is SayItXPCClientError || isStateRequest {
                    return await failed(error)
                }
                throw error
            }
        }
        let completion = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        // Finishing the owned task and resuming its caller are separate turns.
        // Recheck here as well, before a response can reach app projections.
        try check(completion.epoch, cursor: completion.cursor, checksCursor: completion.checksCursor)
        return try completion.result.get()
    }

    func refresh() async throws {
        _ = try await send(.snapshot)
    }

    func restart() async {
        let task = scheduleRepair(automatically: false, afterMismatch: state == .updateRequired)
        _ = await task?.result
    }

    func setEnabled(_ enabled: Bool) async {
        guard lifecycle != .suspended, lifecycle != .stopped else { return }
        if lifecycle == .idle {
            enabledIntent = enabled
            publish(enabled ? .connecting : .disabled, text: nil)
            return
        }
        enabledIntent = enabled
        reset()
        let requestedEpoch = epoch
        enabledChangeEpoch = requestedEpoch
        defer {
            if enabledChangeEpoch == requestedEpoch { enabledChangeEpoch = nil }
        }
        cancelWork()
        publish(enabled ? .connecting : .disabled, text: nil)
        await invalidateTransport()
        await joinWork()
        guard lifecycle == .running, epoch == requestedEpoch else { return }
        let task = own { [self] in
            defer { registrationTask = nil }
            if enabled {
                await registration.enable()
            } else {
                await registration.disable()
            }
            try check(requestedEpoch, requiresEnabled: false)
            enabledIntent = nil
        }
        registrationTask = task
        _ = await task.result
        guard lifecycle == .running, epoch == requestedEpoch else { return }
        startPolling()
    }

    func setPlaybackSurfaceVisible(_ visible: Bool) {
        isPlaybackSurfaceVisible = visible
    }

    func suspend(until deadline: Date) async throws {
        guard lifecycle != .stopped else { await joinWork(); return }
        close(.suspended)
        // Invalidation is itself tracked so deadline expiry cannot lose it.
        beginInvalidation()
        try await clock.wait(until: deadline) { work.isEmpty }
    }

    func stop() async {
        if lifecycle != .stopped {
            close(.stopped)
            beginInvalidation()
        }
        await joinWork()
    }

    private var isEnabled: Bool { enabledIntent ?? !registration.isUserDisabled }
    private var canSend: Bool {
        lifecycle == .running && isEnabled && registrationTask == nil
            && invalidationTask == nil && enabledChangeEpoch == nil && !registration.isWorking
    }

    private func check(
        _ requestedEpoch: UInt64,
        cursor requestedCursor: UInt64? = nil,
        checksCursor: Bool = false,
        requiresEnabled: Bool = true
    ) throws {
        try Task.checkCancellation()
        guard lifecycle == .running, epoch == requestedEpoch,
              (!requiresEnabled || isEnabled),
              (!checksCursor || cursor == requestedCursor) else {
            throw CancellationError()
        }
    }

    private func reset(transportFailure: Bool = false) {
        epoch &+= 1
        cursor = nil
        onOutput(.reset(transportFailure: transportFailure))
    }

    private func publish(_ state: ServiceConnectionState, text: String?) {
        self.state = state
        onOutput(.state(state, statusText: text))
    }

    private func close(_ lifecycle: Lifecycle) {
        self.lifecycle = lifecycle
        reset()
        publish(isEnabled ? .offline : .disabled, text: nil)
        cancelWork()
    }

    private func own<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) -> Task<Value, any Error> {
        let id = UUID()
        let task = Task { @MainActor in
            defer { work[id] = nil }
            return try await operation()
        }
        work[id] = Work(cancel: { task.cancel() }, join: { _ = await task.result })
        return task
    }

    private func cancelWork() {
        for item in work.values { item.cancel() }
    }

    private func joinWork() async {
        // Join the work inherited by this action. A concurrent start may open
        // a replacement; its new poll must not become part of an older drain.
        let pending = Array(work.values)
        for item in pending { await item.join() }
    }

    private func beginInvalidation() {
        guard invalidationTask == nil else { return }
        invalidationTask = own { [self] in
            defer { invalidationTask = nil }
            await transport.invalidate()
        }
    }

    private func invalidateTransport() async {
        beginInvalidation()
        _ = await invalidationTask?.result
    }

    private func startPolling() {
        guard lifecycle == .running, pollTask == nil else { return }
        pollTask = own { [self] in
            defer { pollTask = nil }
            while lifecycle == .running && !Task.isCancelled {
                registration.refresh()
                if !isEnabled {
                    if state != .disabled {
                        reset()
                        publish(.disabled, text: nil)
                        await invalidateTransport()
                    }
                    try await clock.sleep(1)
                    continue
                }
                guard canSend else {
                    try await clock.sleep(0.1)
                    continue
                }
                do {
                    if let cursor {
                        _ = try await send(.waitForEvents(
                            after: cursor,
                            playbackInterval: isPlaybackSurfaceVisible ? 0.25 : 1
                        ))
                    } else {
                        try await refresh()
                    }
                    retryDelay = 0.25
                } catch is CancellationError {
                    if Task.isCancelled || lifecycle != .running { return }
                    // A concurrent refresh advanced the cursor. Keep this loop.
                } catch let failure as ServiceFailure where failure.code == "protocol.version_mismatch" {
                    try await clock.sleep(2)
                } catch {
                    let delay = retryDelay
                    retryDelay = min(retryDelay * 2, 8)
                    try await clock.sleep(delay)
                }
            }
        }
    }

    private func accept(_ response: ServiceResponse, for command: ServiceCommand) throws {
        let snapshot: ServiceSnapshot
        switch (command, response) {
        case (.snapshot, .snapshot(let value)):
            snapshot = value
        case (.waitForEvents, .events(let events)), (.events, .events(let events)):
            guard let event = events.last, cursor.map({ event.id > $0 }) ?? true else { return }
            snapshot = event.snapshot
        case (_, .failure(let failure)):
            throw failure
        default:
            let isSnapshot: Bool
            if case .snapshot = command { isSnapshot = true } else { isSnapshot = false }
            throw ServiceFailure(
                code: isSnapshot ? "service.invalid_snapshot" : "service.invalid_events",
                message: isSnapshot
                    ? "The service returned an invalid state snapshot."
                    : "The service returned an invalid event response."
            )
        }
        guard snapshot.protocolVersion == SayItProtocolVersion.current,
              snapshot.serviceVersion == applicationVersion else {
            throw ServiceFailure(
                code: "protocol.version_mismatch",
                message: "The background service does not match this version of Say It."
            )
        }
        guard cursor.map({ snapshot.revision > $0 }) ?? true else { return }
        cursor = snapshot.revision
        automaticAttempts = 0
        retryDelay = 0.25
        publish(.online(version: snapshot.serviceVersion), text: nil)
        onOutput(.snapshot(snapshot))
    }

    private func failed(_ error: any Error) async -> Completion {
        let mismatch = (error as? ServiceFailure)?.code == "protocol.version_mismatch"
        reset(transportFailure: error is SayItXPCClientError)
        publish(
            mismatch ? .updateRequired : .offline,
            text: mismatch ? "Service update required" : "Background service unavailable"
        )
        _ = scheduleRepair(automatically: true, afterMismatch: mismatch)
        let completion = Completion(
            result: .failure(error), epoch: epoch, cursor: cursor, checksCursor: true
        )
        await invalidateTransport()
        return completion
    }

    @discardableResult
    private func scheduleRepair(
        automatically: Bool,
        afterMismatch: Bool
    ) -> Task<Void, any Error>? {
        guard lifecycle == .running, isEnabled, registrationTask == nil,
              enabledChangeEpoch == nil, !registration.isWorking,
              !registration.requiresApproval else { return nil }
        if automatically {
            guard automaticAttempts < 2 else { return nil }
            automaticAttempts += 1
        }
        reset()
        let requestedEpoch = epoch
        publish(.recovering, text: "Reconnecting background service…")
        let task = own { [self] in
            defer { registrationTask = nil }
            await invalidateTransport()
            try check(requestedEpoch)
            if automatically { try await clock.sleep(1) }
            try check(requestedEpoch)
            registration.refresh()
            guard !registration.isWorking, !registration.requiresApproval else { return }
            await registration.restart()
            try check(requestedEpoch)
            reset()
            let replacementEpoch = epoch
            await invalidateTransport()
            try check(replacementEpoch)
            if registration.errorMessage != nil {
                publish(afterMismatch ? .updateRequired : .offline, text: "Background service needs attention")
            } else {
                publish(.recovering, text: "Connecting to service")
            }
        }
        registrationTask = task
        return task
    }
}
