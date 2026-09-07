import Foundation

/// Retires manually bootstrapped jobs that occupy the installed app's service name.
/// Normal bundled jobs remain under SMAppService's control.
public enum LegacyServiceJobRecovery {
    public static func removeConflict(
        label: String,
        machServiceName: String,
        agentURL: URL,
        bundledPlistURL: URL
    ) async throws {
        try await removeConflict(
            label: label,
            machServiceName: machServiceName,
            agentURL: agentURL,
            bundledPlistURL: bundledPlistURL,
            run: { arguments in
                // launchctl is blocking; never run it on the app's main actor.
                try await Task.detached {
                    try ServiceJobManager.run(arguments)
                }.value
            }
        )
    }

    static func removeConflict(
        label: String,
        machServiceName: String,
        agentURL: URL,
        bundledPlistURL: URL,
        run: @Sendable ([String]) async throws -> (status: Int32, output: String),
        wait: @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async throws {
        try Task.checkCancellation()
        let target = "\(ServiceJobManager.domain)/\(label)"
        let existing = try await run(["print", target])
        if isMissing(existing) { return }
        guard existing.status == 0 else { throw RecoveryError.inspectionFailed }
        guard isConflictingJob(
            existing.output,
            machServiceName: machServiceName,
            agentURL: agentURL,
            bundledPlistURL: bundledPlistURL
        ) else { return }

        try Task.checkCancellation()
        let stopped = try await run(["bootout", target])
        if stopped.status != 0 && !isMissing(stopped) {
            // Another app instance may have retired the job after inspection.
            let remaining = try await run(["print", target])
            if isMissing(remaining) { return }
            throw RecoveryError.stopFailed
        }
        for _ in 0..<50 {
            try Task.checkCancellation()
            let remaining = try await run(["print", target])
            if isMissing(remaining) { return }
            guard remaining.status == 0 else { throw RecoveryError.inspectionFailed }
            try await wait()
        }
        throw RecoveryError.stopTimedOut
    }

    static func isConflictingJob(
        _ output: String,
        machServiceName: String,
        agentURL: URL,
        bundledPlistURL: URL
    ) -> Bool {
        // Match top-level fields exactly, never arbitrary substrings in arguments
        // or environment values. Unrecognized launchctl output is left untouched.
        let lines = output.split(separator: "\n").map(String.init)
        func field(_ name: String) -> String? {
            let prefix = "\t\(name) = "
            return lines.first(where: { $0.hasPrefix(prefix) })
                .map { String($0.dropFirst(prefix.count)) }
        }
        guard let program = field("program"), let path = field("path"),
              program.hasPrefix("/"), path.hasPrefix("/"),
              URL(filePath: program).standardizedFileURL.resolvingSymlinksInPath()
                == agentURL.standardizedFileURL.resolvingSymlinksInPath(),
              URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
                != bundledPlistURL.standardizedFileURL.resolvingSymlinksInPath(),
              !path.contains(".app/Contents/Library/LaunchAgents/"),
              lines.contains("\t\t\"\(machServiceName)\" = {") else {
            return false
        }
        return true
    }

    private static func isMissing(_ result: (status: Int32, output: String)) -> Bool {
        result.status != 0 && result.output.contains("Could not find service")
    }

    enum RecoveryError: LocalizedError {
        case inspectionFailed, stopFailed, stopTimedOut

        var errorDescription: String? {
            switch self {
            case .inspectionFailed:
                "Say It could not check for an older background service."
            case .stopFailed:
                "Say It could not stop the older background service. Quit other copies of Say It and try again."
            case .stopTimedOut:
                "The older background service did not stop in time. Quit other copies of Say It and try again."
            }
        }
    }
}
