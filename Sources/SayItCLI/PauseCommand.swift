import ArgumentParser

struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause playback."
    )

    func run() async throws {
        try await CLICommandSupport.run(.pause)
    }
}
