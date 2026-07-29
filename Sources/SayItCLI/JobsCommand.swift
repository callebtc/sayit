import ArgumentParser
import SayItProtocol

struct JobsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "List recent speech jobs."
    )

    @Flag(name: .long)
    var json = false

    func run() async throws {
        do {
            let response = try await CLIService().call(.jobs)
            guard case .jobs(let jobs) = response else { return }
            if json {
                try CLIOutput.json(jobs)
            } else {
                for job in jobs {
                    CLIOutput.standard(
                        "\(job.id.uuidString)\t\(job.state.rawValue)\t\(job.title)"
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
