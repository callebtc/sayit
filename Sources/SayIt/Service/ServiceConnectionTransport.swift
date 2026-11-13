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
