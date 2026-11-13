@preconcurrency import Foundation
import SayItProtocol
import Synchronization

public actor SayItXPCClient {
    private let connectionFactory: @Sendable () -> any SayItXPCConnection

    private struct Connection {
        let id = UUID()
        let transport: any SayItXPCConnection
    }

    private struct PendingRequest {
        let connectionID: UUID
        let continuation: CheckedContinuation<ServiceResponse, any Error>
        let cancellation: RequestCancellation
    }

    private var connection: Connection?
    private var pending: [UUID: PendingRequest] = [:]

    public init(
        machServiceName: String = SayItServiceIdentifiers.machService
    ) {
        self.connectionFactory = {
            NSXPCServiceConnection(machServiceName: machServiceName)
        }
    }

    init(connectionFactory: @escaping @Sendable () -> any SayItXPCConnection) {
        self.connectionFactory = connectionFactory
    }

    public func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try await send(ServiceRequest(command: command))
    }

    public func send(_ request: ServiceRequest) async throws -> ServiceResponse {
        try Task.checkCancellation()
        // Each send owns a lifetime, even when callers reuse a wire request ID.
        let requestID = UUID()
        let cancellation = RequestCancellation()
        let requestData = try SayItWireCodec.encode(request)
        return try await withTaskCancellationHandler {
            let needsActivation = connection == nil
            let active = connection ?? Connection(transport: connectionFactory())
            connection = active
            let connectionID = active.id
            return try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = PendingRequest(
                    connectionID: connectionID,
                    continuation: continuation,
                    cancellation: cancellation
                )
                if needsActivation {
                    active.transport.activate { [weak self] error in
                        await self?.retire(connectionID, with: .failure(error))
                    }
                }
                guard !cancellation.isCancelled else {
                    finish(requestID, with: .failure(CancellationError()))
                    return
                }
                active.transport.send(requestData) { [weak self] result in
                    await self?.receive(result, for: requestID, from: connectionID)
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.finish(requestID, with: .failure(CancellationError())) }
        }
    }

    public func invalidate() {
        if let connection {
            retire(connection.id, with: .failure(CancellationError()))
        }
    }

    private func receive(
        _ result: Result<Data, SayItXPCClientError>,
        for requestID: UUID,
        from connectionID: UUID
    ) {
        guard pending[requestID]?.connectionID == connectionID else { return }
        switch result {
        case .success(let data):
            do {
                let response = try SayItWireCodec.decode(ServiceResponse.self, from: data)
                finish(requestID, with: .success(response))
            } catch {
                finish(requestID, with: .failure(SayItXPCClientError.invalidResponse))
            }
        case .failure(let error):
            retire(connectionID, with: .failure(error))
        }
    }

    private func retire(_ connectionID: UUID, with result: Result<ServiceResponse, any Error>) {
        guard let active = connection, active.id == connectionID else { return }
        connection = nil
        let requestIDs = pending.compactMap { id, request in
            request.connectionID == connectionID ? id : nil
        }
        for requestID in requestIDs {
            finish(requestID, with: result)
        }
        active.transport.invalidate()
    }

    private func finish(_ requestID: UUID, with result: Result<ServiceResponse, any Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        if request.cancellation.isCancelled {
            request.continuation.resume(throwing: CancellationError())
        } else {
            request.continuation.resume(with: result)
        }
    }
}

private final class RequestCancellation: Sendable {
    // onCancel runs outside the actor, including before registration. The flag
    // prevents dispatch while the actor's cancellation message is still queued.
    private let cancelled = Mutex(false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

/// The system boundary used by the production client and deterministic tests.
/// Callbacks return after the client has consumed the event, so scripted
/// connections can gate subsequent events without scheduler assumptions.
protocol SayItXPCConnection: Sendable {
    func activate(onFailure: @escaping @Sendable (SayItXPCClientError) async -> Void)
    func send(
        _ request: Data,
        reply: @escaping @Sendable (Result<Data, SayItXPCClientError>) async -> Void
    )
    func invalidate()
}

// NSXPCConnection supports concurrent use; configuration happens before resume.
private final class NSXPCServiceConnection: SayItXPCConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(machServiceName: String) {
        connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: []
        )
        if let requirement = SayItCodeSigningRequirement
            .forBundleIdentifiers([SayItServiceIdentifiers.agentBundle]) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.remoteObjectInterface = NSXPCInterface(
            with: SayItXPCProtocol.self
        )
    }

    deinit {
        connection.invalidate()
    }

    func activate(onFailure: @escaping @Sendable (SayItXPCClientError) async -> Void) {
        connection.interruptionHandler = {
            let error = SayItXPCClientError.requestFailed(
                CocoaError(.xpcConnectionInterrupted).localizedDescription
            )
            Task {
                await onFailure(error)
            }
        }
        connection.invalidationHandler = {
            let error = SayItXPCClientError.requestFailed(
                CocoaError(.xpcConnectionInvalid).localizedDescription
            )
            Task {
                await onFailure(error)
            }
        }
        connection.resume()
    }

    func send(
        _ request: Data,
        reply: @escaping @Sendable (Result<Data, SayItXPCClientError>) async -> Void
    ) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let failure = SayItXPCClientError.requestFailed(error.localizedDescription)
            Task { await reply(.failure(failure)) }
        }
        guard let service = proxy as? SayItXPCProtocol else {
            Task { await reply(.failure(.connectionUnavailable)) }
            return
        }
        service.perform(request) { data in
            Task { await reply(.success(data)) }
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}
