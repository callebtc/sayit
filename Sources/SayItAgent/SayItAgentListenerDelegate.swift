import Foundation
import SayItBackend
import SayItXPC

final class SayItAgentListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let backend: SayItBackendService
    private let validator = SayItClientValidator()
    private let connectionLock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    var codeSigningRequirement: String? {
        validator.codeSigningRequirement
    }

    init(backend: SayItBackendService) {
        self.backend = backend
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validator.accepts(connection) else {
            return false
        }
        let sessionService = SayItXPCExportedService(backend: backend)
        connection.exportedInterface = NSXPCInterface(
            with: SayItXPCProtocol.self
        )
        connection.exportedObject = sessionService
        let identifier = ObjectIdentifier(connection)
        connectionLock.withLock {
            connections[identifier] = connection
        }
        connection.interruptionHandler = {
            sessionService.cancelAllRequests(invalidate: false)
        }
        connection.invalidationHandler = { [weak self] in
            sessionService.cancelAllRequests(invalidate: true)
            self?.connectionLock.withLock {
                self?.connections[identifier] = nil
            }
        }
        connection.resume()
        return true
    }
}
