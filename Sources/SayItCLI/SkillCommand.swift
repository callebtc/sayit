import ArgumentParser
import SayItCore

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Locate the bundled Say It agent skill.",
        subcommands: [SkillPathCommand.self]
    )
}

struct SkillPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the bundled Say It agent skill path."
    )

    func run() throws {
        guard let skillURL = SayItSkill.bundledURL else {
            throw ValidationError("The bundled Say It agent skill is missing.")
        }
        CLIOutput.standard(skillURL.path)
    }
}
