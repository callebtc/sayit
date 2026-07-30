import Foundation
import SayItProtocol
import SayItXPC

final class SayItSelectionListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let service = SayItSelectionXPCExportedService()
    private let validator = SayItClientValidator(
        trustedBundleIdentifiers: [
            SayItServiceIdentifiers.applicationBundle
        ]
    )
    private let connectionLock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    var codeSigningRequirement: String? {
        validator.codeSigningRequirement
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validator.accepts(connection) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(
            with: SelectionXPCProtocol.self
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
