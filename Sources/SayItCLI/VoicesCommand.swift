import ArgumentParser
import SayItProtocol

struct VoicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voices",
        abstract: "List saved voice profiles."
    )

    @Option(name: .long, help: "Only list voices for this model.")
    var model: String?

    @Flag(name: .long, help: "Write machine-readable JSON.")
    var json = false

    func run() async throws {
        do {
            let response = try await CLIService().call(
                .voices(modelID: model)
            )
            guard case .voices(let voices) = response else { return }
            if json {
                try CLIOutput.json(voices)
            } else if voices.isEmpty {
                CLIOutput.standard("No saved voices.")
            } else {
                for voice in voices {
                    CLIOutput.standard(
                        "\(voice.id.uuidString.lowercased())\t\(voice.displayName)\t\(voice.modelID)\t\(voice.origin.rawValue)"
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
