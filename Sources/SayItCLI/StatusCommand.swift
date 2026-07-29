import ArgumentParser
import SayItProtocol

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show service and playback state."
    )

    @Flag(name: .long)
    var json = false

    func run() async throws {
        do {
            let response = try await CLIService().call(.snapshot)
            guard case .snapshot(let snapshot) = response else { return }
            if json {
                try CLIOutput.json(snapshot)
            } else {
                CLIOutput.standard(
                    "\(snapshot.statusText) · \(snapshot.playback.state)"
                )
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
