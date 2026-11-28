@preconcurrency import Foundation
import SayItProtocol

public actor SayItXPCClient {
    private let machServiceName: String
    private let connectionFactory: (@Sendable () -> NSXPCConnection)?
    private var connection: NSXPCConnection?

    public init(
        machServiceName: String = SayItServiceIdentifiers.machService
    ) {
        self.machServiceName = machServiceName
        connectionFactory = nil
    }

    init(
        connectionFactory: @escaping @Sendable () -> NSXPCConnection
    ) {
        machServiceName = ""
        self.connectionFactory = connectionFactory
    }

    public func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try await send(ServiceRequest(command: command))
    }

    public func send(_ request: ServiceRequest) async throws -> ServiceResponse {
        try Task.checkCancellation()
        let requestData = try SayItWireCodec.encode(request)
        let connection = connection ?? makeConnection()
        self.connection = connection
        let gate = OneShotContinuation<ServiceResponse>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else {
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                    Task {
                        await self?.invalidate()
                    }
                    gate.resume(
                        with: .failure(
                            SayItXPCClientError.requestFailed(
                                error.localizedDescription
                            )
                        )
                    )
                }
                guard let service = proxy as? SayItXPCProtocol else {
                    gate.resume(
                        with: .failure(SayItXPCClientError.connectionUnavailable)
                    )
                    return
                }
                service.perform(requestData) { data in
                    do {
                        let response = try SayItWireCodec.decode(
                            ServiceResponse.self,
                            from: data
                        )
                        gate.resume(with: .success(response))
                    } catch {
                        gate.resume(
                            with: .failure(SayItXPCClientError.invalidResponse)
                        )
                    }
                }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func makeConnection() -> NSXPCConnection {
        if let connectionFactory {
            let connection = connectionFactory()
            connection.remoteObjectInterface = NSXPCInterface(
                with: SayItXPCProtocol.self
            )
            connection.resume()
            return connection
        }
        let connection = NSXPCConnection(
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
        connection.resume()
        return connection
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let early: Result<Value, Error>? = lock.withLock {
            if isFinished {
                let result = pendingResult
                pendingResult = nil
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
            return false
        }
        return true
    }

    func resume(with result: Result<Value, Error>) {
        let continuationToResume: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pendingResult = result
            return nil
        }
        continuationToResume?.resume(with: result)
    }
}
