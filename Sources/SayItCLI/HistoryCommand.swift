import ArgumentParser
import SayItProtocol

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List speech history."
    )

    @Flag(name: .long)
    var json = false

    func run() async throws {
        do {
            let response = try await CLIService().call(.history)
            guard case .history(let history) = response else { return }
            if json {
                try CLIOutput.json(history)
            } else {
                for item in history {
                    CLIOutput.standard(
                        "\(item.id.uuidString)\t\(item.title)"
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
