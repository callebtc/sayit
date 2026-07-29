import ArgumentParser
import SayItProtocol

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List speech models."
    )

    @Flag(name: .long)
    var json = false

    func run() async throws {
        do {
            let response = try await CLIService().call(.models)
            guard case .models(let models) = response else { return }
            if json {
                try CLIOutput.json(models)
            } else {
                for model in models {
                    CLIOutput.standard(
                        "\(model.id)\t\(model.displayName)"
                    )
                }
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
