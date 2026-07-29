import ArgumentParser

struct SkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Skip forward or backward by seconds."
    )

    @Argument(help: "Signed number of seconds.")
    var seconds: Double

    func run() async throws {
        try await CLICommandSupport.run(.skip(seconds))
    }
}
