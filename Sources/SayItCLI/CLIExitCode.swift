import ArgumentParser

enum CLIExitCode {
    static let unavailable = ExitCode(69)
    static let rejected = ExitCode(65)
    static let canceled = ExitCode(130)
    static let synthesisFailed = ExitCode(70)
}
