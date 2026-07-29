import ArgumentParser

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Alias for clear."
    )

    func run() async throws {
        try await CLICommandSupport.run(.clear)
    }
}
