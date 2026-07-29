import ArgumentParser

struct ResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume playback."
    )

    func run() async throws {
        try await CLICommandSupport.run(.play)
    }
}
