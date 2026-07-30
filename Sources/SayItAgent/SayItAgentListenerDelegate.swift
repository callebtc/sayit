import Foundation
import SayItBackend
import SayItXPC

final class SayItAgentListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let service: SayItXPCExportedService
    private let validator = SayItClientValidator()
    private let connectionLock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    var codeSigningRequirement: String? {
        validator.codeSigningRequirement
    }

    init(backend: SayItBackendService) {
        service = SayItXPCExportedService(backend: backend)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validator.accepts(connection) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(
            with: SayItXPCProtocol.self
        )
        connection.exportedObject = service
        let identifier = ObjectIdentifier(connection)
        connectionLock.withLock {
            connections[identifier] = connection
        }
        connection.invalidationHandler = { [weak self] in
            self?.connectionLock.withLock {
                self?.connections[identifier] = nil
            }
        }
        connection.resume()
        return true
    }
}
