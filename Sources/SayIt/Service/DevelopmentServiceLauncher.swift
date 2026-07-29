#if DEBUG
import Darwin
import Foundation
import SayItProtocol

enum DevelopmentServiceLauncher {
    private static let label = "com.sayit.mac.agent"

    static func ensureRunning(agentURL: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw LauncherError.agentMissing
        }

        let domain = "gui/\(geteuid())"
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "\(label).debug.log")
        let existing = try run(["print", "\(domain)/\(label)"])
        if existing.status == 0,
           existing.output.contains(agentURL.path),
           existing.output.contains(SayItServiceIdentifiers.machService),
           existing.output.contains(logURL.path) {
            let result = try run([
                "kickstart",
                "-k",
                "\(domain)/\(label)"
            ])
            guard result.status == 0 else {
                throw LauncherError.launchctl(result.output)
            }
            return
        }

        if existing.status == 0 {
            _ = try run(["bootout", "\(domain)/\(label)"])
        }

        let propertyListURL = FileManager.default.temporaryDirectory
            .appending(path: "\(label).debug.plist")
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [agentURL.path],
            "MachServices": [
                SayItServiceIdentifiers.machService: true
            ],
            "ProcessType": "Interactive",
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: propertyListURL, options: .atomic)

        var lastResult: (status: Int32, output: String)?
        for attempt in 0..<20 {
            let result = try run([
                "bootstrap",
                domain,
                propertyListURL.path
            ])
            if result.status == 0 {
                return
            }
            lastResult = result
            if attempt < 19 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw LauncherError.launchctl(lastResult?.output ?? "")
    }

    static func unregister() throws {
        let domain = "gui/\(geteuid())"
        let result = try run(["bootout", "\(domain)/\(label)"])
        guard result.status == 0 || result.output.contains("Could not find") else {
            throw LauncherError.launchctl(result.output)
        }
    }

    private static func run(
        _ arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    private enum LauncherError: LocalizedError {
        case agentMissing
        case launchctl(String)

        var errorDescription: String? {
            switch self {
            case .agentMissing:
                "The bundled background service is missing."
            case .launchctl(let output):
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? "The background service could not be started."
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
#endif
