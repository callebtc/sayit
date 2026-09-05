import SayItProtocol
import SayItXPC

actor CLIService {
    private let client = SayItXPCClient()

    func call(_ command: ServiceCommand) async throws -> ServiceResponse {
        let response = try await client.send(command)
        if case .failure(let failure) = response {
            if failure.code == "protocol.version_mismatch" {
                throw ServiceFailure(
                    code: failure.code,
                    message: """
                    The running Say It service is incompatible with this CLI \
                    (protocol \(SayItProtocolVersion.current)). Quit all copies of \
                    Say It, reopen the app containing this CLI, and try again. \
                    If multiple copies are installed, reinstall the command \
                    from the app you use.
                    """
                )
            }
            throw failure
        }
        return response
    }
}
