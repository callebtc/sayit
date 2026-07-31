import Foundation
import SayItProtocol

@main
struct SayItSelectionAgentMain {
    static func main() {
        let delegate = SayItSelectionListenerDelegate()
        let listener = NSXPCListener(
            machServiceName: SayItServiceIdentifiers.selectionMachService
        )
        if let requirement = delegate.codeSigningRequirement {
            listener.setConnectionCodeSigningRequirement(requirement)
        }
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) {
            RunLoop.main.run()
        }
    }
}
