import SayItProtocol
import SayItXPC

actor CLIService {
    private let client = SayItXPCClient()

    func call(_ command: ServiceCommand) async throws -> ServiceResponse {
        let response = try await client.send(command)
        if case .failure(let failure) = response {
            throw failure
        }
        return response
    }
}
