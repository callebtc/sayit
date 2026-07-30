@preconcurrency import Foundation
import SayItProtocol

public actor SayItXPCClient {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    public init(
        machServiceName: String = SayItServiceIdentifiers.machService
    ) {
        self.machServiceName = machServiceName
    }

    public func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try await send(ServiceRequest(command: command))
    }

    public func send(_ request: ServiceRequest) async throws -> ServiceResponse {
        let requestData = try SayItWireCodec.encode(request)
        let connection = connection ?? makeConnection()
        self.connection = connection

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                Task {
                    await self?.invalidate()
                }
                continuation.resume(
                    throwing: SayItXPCClientError.requestFailed(
                        error.localizedDescription
                    )
                )
            }
            guard let service = proxy as? SayItXPCProtocol else {
                continuation.resume(
                    throwing: SayItXPCClientError.connectionUnavailable
                )
                return
            }
            service.perform(requestData) { data in
                do {
                    let response = try SayItWireCodec.decode(
                        ServiceResponse.self,
                        from: data
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(
                        throwing: SayItXPCClientError.invalidResponse
                    )
                }
            }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func makeConnection() -> NSXPCConnection {
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
