import ArgumentParser
import Foundation
import SayItProtocol
import SayItXPC

struct ServiceControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage the Say It background service.",
        subcommands: [
            ServiceStartCommand.self,
            ServiceStopCommand.self,
            ServiceRestartCommand.self,
            ServiceStatusCommand.self
        ]
    )
}

struct ServiceStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the background service."
    )

    func run() async throws {
        do {
            try await CLIServiceJob.ensureRunning()
            CLIOutput.standard("Say It background service started.")
        } catch {
            CLIOutput.status(error.localizedDescription)
            CLIOutput.status(
                "Open the Say It app to start the service instead."
            )
            throw CLIExitCode.unavailable
        }
    }
}

struct ServiceStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the background service."
    )

    func run() async throws {
        do {
            try CLIServiceJob.shutdown()
            CLIOutput.standard("Say It background service stopped.")
        } catch {
            CLIOutput.status(error.localizedDescription)
            throw CLIExitCode.unavailable
        }
    }
}

struct ServiceRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the background service."
    )

    func run() async throws {
        do {
            try CLIServiceJob.shutdown()
            try await CLIServiceJob.ensureRunning()
            CLIOutput.standard("Say It background service restarted.")
        } catch {
            CLIOutput.status(error.localizedDescription)
            CLIOutput.status(
                "Open the Say It app to restart the service instead."
            )
            throw CLIExitCode.unavailable
        }
    }
}

struct ServiceStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check whether the background service is running."
    )

    func run() async throws {
        do {
            let response = try await CLIService().call(.snapshot)
            guard case .snapshot(let snapshot) = response else { return }
            CLIOutput.standard(
                "Running · version \(snapshot.serviceVersion)"
            )
        } catch {
            CLIOutput.status("Say It background service is not running.")
            throw CLIExitCode.unavailable
        }
    }
}

enum CLIServiceJob {
    static func ensureRunning() async throws {
        try await jobManager().ensureRunning()
    }

    static func shutdown() throws {
        try jobManager().shutdown()
    }

    private static func jobManager() -> ServiceJobManager {
        ServiceJobManager(
            label: label,
            machServiceName: SayItServiceIdentifiers.machService,
            agentURL: agentURL(),
            logURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).log"),
            propertyListURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).plist")
        )
    }

    private static var label: String {
        #if DEBUG || SAYIT_LOCAL_BUILD
        "com.sayit.mac.agent.debug"
        #else
        "com.sayit.mac.agent"
        #endif
    }

    private static func agentURL() -> URL {
        for candidate in candidates() where
            FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return candidates()[0]
    }

    private static func candidates() -> [URL] {
        var urls: [URL] = []
        let executable = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).resolvingSymlinksInPath()
        urls.append(
            executable
                .deletingLastPathComponent()
                .appending(path: "../Library/LaunchServices/SayItAgent")
                .standardizedFileURL
        )
        urls.append(
            URL(filePath:
                "/Applications/SayIt.app/Contents/Library/LaunchServices/SayItAgent"
            )
        )
        urls.append(
            URL.homeDirectory.appending(path:
                "Applications/SayIt.app/Contents/Library/LaunchServices/SayItAgent"
            )
        )
        return urls
    }
}
