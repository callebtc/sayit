import ArgumentParser

@main
struct SayItCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sayit",
        abstract: "Read text aloud using the Say It background service.",
        subcommands: [
            SpeakCommand.self,
            StatusCommand.self,
            JobsCommand.self,
            PauseCommand.self,
            ResumeCommand.self,
            ClearCommand.self,
            StopCommand.self,
            SeekCommand.self,
            SkipCommand.self,
            ModelsCommand.self,
            VoicesCommand.self,
            HistoryCommand.self,
            ServiceControlCommand.self
        ],
        defaultSubcommand: SpeakCommand.self
    )
}
