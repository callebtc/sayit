import Darwin
import Foundation

public struct ServiceJobManager: Sendable {
    public let label: String
    public let machServiceName: String
    public let agentURL: URL
    public let logURL: URL
    public let propertyListURL: URL

    public init(
        label: String,
        machServiceName: String,
        agentURL: URL,
        logURL: URL,
        propertyListURL: URL
    ) {
        self.label = label
        self.machServiceName = machServiceName
        self.agentURL = agentURL
        self.logURL = logURL
        self.propertyListURL = propertyListURL
    }

    public func isLoaded() -> Bool {
        Self.printJob(label: label)?.status == 0
    }

    public static func printJob(
        label: String
    ) -> (status: Int32, output: String)? {
        try? run(["print", "\(domain)/\(label)"])
    }

    public static func shutdown(label: String) throws {
        let result = try run(["bootout", "\(domain)/\(label)"])
        guard result.status == 0 || result.output.contains("Could not find") else {
            throw JobError.launchctl(result.output)
        }
    }

    public func ensureRunning() async throws {
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw JobError.agentMissing(agentURL.path)
        }

        let existing = try Self.run(["print", "\(Self.domain)/\(label)"])
        if existing.status == 0,
           existing.output.contains(agentURL.path),
           existing.output.contains(machServiceName),
           existing.output.contains(logURL.path) {
            let result = try Self.run([
                "kickstart",
                "-k",
                "\(Self.domain)/\(label)"
            ])
            guard result.status == 0 else {
                throw JobError.launchctl(result.output)
            }
            return
        }

        if existing.status == 0 {
            _ = try Self.run(["bootout", "\(Self.domain)/\(label)"])
        }

        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [agentURL.path],
            "MachServices": [
                machServiceName: true
            ],
            "ProcessType": "Interactive",
            "RunAtLoad": true,
            "KeepAlive": false,
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
            let result = try Self.run([
                "bootstrap",
                Self.domain,
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
        throw JobError.launchctl(lastResult?.output ?? "")
    }

    public func shutdown() throws {
        try Self.shutdown(label: label)
    }

    private static var domain: String {
        "gui/\(geteuid())"
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

    public enum JobError: LocalizedError {
        case agentMissing(String)
        case launchctl(String)

        public var errorDescription: String? {
            switch self {
            case .agentMissing(let path):
                "The bundled background service is missing at \(path)."
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
