import ArgumentParser

struct SeekCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seek",
        abstract: "Seek to an absolute playback time."
    )

    @Argument(help: "Playback time in seconds.")
    var seconds: Double

    func run() async throws {
        try await CLICommandSupport.run(.seek(seconds))
    }
}
