import Foundation
import SayItProtocol
import SayItXPC

@MainActor
protocol ServiceConnectionTransport {
    func send(_ command: ServiceCommand) async throws -> ServiceResponse
    func invalidate() async
}

@MainActor
struct XPCServiceConnectionTransport: ServiceConnectionTransport {
    private let client = SayItXPCClient()

    func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try await client.send(command)
    }

    func invalidate() async {
        await client.invalidate()
    }
}

@MainActor
protocol ServiceConnectionRegistration {
    var isUserDisabled: Bool { get }
    var isWorking: Bool { get }
    var requiresApproval: Bool { get }
    var errorMessage: String? { get }
    func refresh()
    func ensureRunning() async
    func enable() async
    func disable() async
    func restart() async
}

extension BackgroundServiceController: ServiceConnectionRegistration {}

@MainActor
struct ServiceConnectionClock {
    var now: () -> Date
    var sleep: (TimeInterval) async throws -> Void

    static let system = ServiceConnectionClock(
        now: { Date.now },
        sleep: { try await Task.sleep(for: .seconds($0)) }
    )
}
