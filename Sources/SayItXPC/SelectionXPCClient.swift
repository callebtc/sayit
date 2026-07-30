@preconcurrency import Foundation
import SayItProtocol

public actor SelectionXPCClient {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    public init(
        machServiceName: String = SayItServiceIdentifiers.selectionMachService
    ) {
        self.machServiceName = machServiceName
    }

    public func send(
        _ request: SelectionServiceRequest
    ) async throws -> SelectionServiceResponse {
        let requestData = try SayItWireCodec.encode(request)
        return try await send(
            requestData,
            retryingConnectionFailure: true
        )
    }

    private func send(
        _ requestData: Data,
        retryingConnectionFailure: Bool
    ) async throws -> SelectionServiceResponse {
        let activeConnection = connection ?? makeConnection()
        connection = activeConnection
        do {
            return try await perform(
                requestData,
                using: activeConnection
            )
        } catch {
            invalidate(activeConnection)
            guard retryingConnectionFailure, shouldRetry(error) else {
                throw error
            }
            return try await send(
                requestData,
                retryingConnectionFailure: false
            )
        }
    }

    private func perform(
        _ requestData: Data,
        using connection: NSXPCConnection
    ) async throws -> SelectionServiceResponse {
        try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler {
                error in
                continuation.resume(
                    throwing: SelectionXPCClientError.requestFailed(
                        error.localizedDescription
                    )
                )
            }
            guard let service = proxy as? SelectionXPCProtocol else {
                continuation.resume(
                    throwing: SelectionXPCClientError.connectionUnavailable
                )
                return
            }
            service.perform(requestData) { data in
                do {
                    continuation.resume(
                        returning: try SayItWireCodec.decode(
                            SelectionServiceResponse.self,
                            from: data
                        )
                    )
                } catch {
                    continuation.resume(
                        throwing: SelectionXPCClientError.invalidResponse
                    )
                }
            }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func invalidate(_ failedConnection: NSXPCConnection) {
        failedConnection.invalidate()
        if connection === failedConnection {
            connection = nil
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? SelectionXPCClientError else {
            return false
        }
        return switch error {
        case .connectionUnavailable, .requestFailed:
            true
        case .invalidResponse:
            false
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: []
        )
        if let requirement = SayItCodeSigningRequirement
            .forBundleIdentifiers([
                SayItServiceIdentifiers.selectionAgentBundle
            ]) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.remoteObjectInterface = NSXPCInterface(
            with: SelectionXPCProtocol.self
        )
        connection.resume()
        return connection
    }
}
