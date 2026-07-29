import ArgumentParser
import SayItProtocol

enum CLICommandSupport {
    static func run(
        _ command: ServiceCommand,
        expectsJSON: Bool = false
    ) async throws {
        do {
            let response = try await CLIService().call(command)
            if expectsJSON {
                try CLIOutput.json(response)
            }
        } catch let failure as ServiceFailure {
            CLIOutput.status(failure.message)
            throw CLIExitCode.rejected
        } catch {
            CLIOutput.status("Say It background service is unavailable.")
            throw CLIExitCode.unavailable
        }
    }
}
