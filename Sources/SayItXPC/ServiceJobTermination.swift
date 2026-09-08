import Darwin
import Foundation

/// Stops one launchd job and waits for its original process to exit.
/// All subprocesses share the caller's deadline; no process-name killing is used.
public enum ServiceJobTermination {
    public static func stop(label: String, deadline: Date) async throws {
        let target = "gui/\(geteuid())/\(label)"
        let snapshot = try await run(["print", target], deadline: deadline)
        guard snapshot.status == 0 else {
            guard isMissingJob(status: snapshot.status) else { throw StopError.failed }
            return
        }
        let pid = processID(in: snapshot.output)
        let result = try await run(["bootout", target], deadline: deadline)
        guard result.status == 0 || isMissingJob(status: result.status) else {
            throw StopError.failed
        }
        while true {
            try Task.checkCancellation()
            guard Date.now < deadline else { throw StopError.timedOut }
            let job = try await run(["print", target], deadline: deadline)
            let exited = pid.map { kill($0, 0) == -1 && errno == ESRCH } ?? true
            if isMissingJob(status: job.status), exited { return }
            if job.status != 0 && !isMissingJob(status: job.status) { throw StopError.failed }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public static func processID(in output: String) -> pid_t? {
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count == 3, parts[0] == "pid", parts[1] == "=",
               let pid = pid_t(parts[2]), pid > 1 {
                return pid
            }
        }
        return nil
    }

    private static func isMissingJob(status: Int32) -> Bool {
        status == ESRCH || status == 113 // launchctl: service not found
    }

    private static func run(_ arguments: [String], deadline: Date) async throws -> (status: Int32, output: String) {
        guard Date.now < deadline else { throw StopError.timedOut }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        // Drain concurrently: launchctl print can exceed a pipe's capacity.
        let output = Task.detached {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            while process.isRunning {
                try Task.checkCancellation()
                guard Date.now < deadline else { throw StopError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            let data = await output.value
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            if process.isRunning { process.terminate() }
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
    }

    public enum StopError: LocalizedError {
        case failed
        case timedOut

        public var errorDescription: String? {
            "A background service could not be stopped. Try the update again when active work has finished."
        }
    }
}
