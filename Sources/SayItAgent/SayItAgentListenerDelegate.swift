import Foundation
import SayItBackend
import SayItXPC

final class SayItAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: SayItXPCExportedService
    private let validator = SayItClientValidator()

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
        connection.resume()
        return true
    }
}
