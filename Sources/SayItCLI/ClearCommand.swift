import ArgumentParser

struct ClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear active speech and continue the queue."
    )

    func run() async throws {
        try await CLICommandSupport.run(.clear)
    }
}
