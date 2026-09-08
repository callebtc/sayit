import Foundation
import Testing
@testable import SayItXPC

@Suite("Legacy service job recovery")
struct LegacyServiceJobRecoveryTests {
    private let label = "test.sayit.recovery"
    private let machService = "test.sayit.recovery.endpoint"
    private let agent = URL(filePath: "/Applications/Example.app/Contents/MacOS/Helper")
    private let bundledPlist = URL(filePath: "/Applications/Example.app/Contents/Library/LaunchAgents/agent.plist")

    private func job(program: String? = nil, path: String = "/tmp/test-agent.plist") -> String {
        """
        test = {
        \tpath = \(path)
        \tprogram = \(program ?? agent.path)
        \tendpoints = {
        \t\t"\(machService)" = {
        \t\t\tactive = 1
        \t\t}
        \t}
        }
        """
    }

    @Test("A stale manual job is stopped and reaped before returning")
    func removesStaleJob() async throws {
        let runner = Runner(results: [
            (0, job()), (0, ""), (0, job()), (113, "Could not find service")
        ])
        try await recover(runner)
        let commands = await runner.commands
        #expect(commands.map { $0[0] } == ["print", "bootout", "print", "print"])
        #expect(commands.allSatisfy { $0.last?.hasSuffix("/\(label)") == true })
    }

    @Test("Normal bundled jobs and other executables are never booted out")
    func preservesOtherJobs() async throws {
        let outputs = [
            job(path: bundledPlist.path),
            job(path: "/Applications/Other.app/Contents/Library/LaunchAgents/agent.plist"),
            job(program: agent.path + "-other"),
            job().replacingOccurrences(of: machService, with: machService + ".other"),
            job().replacingOccurrences(of: "\tprogram", with: "\t\tprogram"),
            "unrecognized output"
        ]
        for output in outputs {
            let runner = Runner(results: [(0, output)])
            try await recover(runner)
            #expect(await runner.commands.count == 1)
        }
    }

    @Test("Missing jobs need no cleanup; inspection failures are not treated as missing")
    func missingAndInspectionFailure() async throws {
        let missing = Runner(results: [(113, "Could not find service")])
        try await recover(missing)
        let denied = Runner(results: [(1, "Operation not permitted")])
        await #expect(throws: LegacyServiceJobRecovery.RecoveryError.self) {
            try await recover(denied)
        }
        #expect(await denied.commands.count == 1)
    }

    @Test("Bootout errors and a job that never exits fail recovery")
    func stopFailures() async {
        let denied = Runner(results: [(0, job()), (1, "Operation not permitted"), (0, job())])
        await #expect(throws: LegacyServiceJobRecovery.RecoveryError.self) {
            try await recover(denied)
        }
        let stuck = Runner(results: [(0, job()), (0, "")], fallback: (0, job()))
        await #expect(throws: LegacyServiceJobRecovery.RecoveryError.self) {
            try await recover(stuck)
        }
        #expect(await stuck.commands.count == 52)
    }

    @Test("Concurrent removal after inspection is harmless")
    func concurrentRemoval() async throws {
        let runner = Runner(results: [
            (0, job()), (3, "No such process"), (113, "Could not find service")
        ])
        try await recover(runner)
        #expect(await runner.commands.count == 3)
    }

    @Test("Cancellation stops cleanup before bootout")
    func cancellation() async {
        let runner = Runner(results: [(0, job())])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await recover(runner)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runner.commands.isEmpty)
    }

    private func recover(_ runner: Runner) async throws {
        try await LegacyServiceJobRecovery.removeConflict(
            label: label,
            machServiceName: machService,
            agentURL: agent,
            bundledPlistURL: bundledPlist,
            run: { await runner.run($0) },
            wait: {}
        )
    }

    private actor Runner {
        var commands: [[String]] = []
        var results: [(Int32, String)]
        let fallback: (Int32, String)

        init(results: [(Int32, String)], fallback: (Int32, String) = (113, "Could not find service")) {
            self.results = results
            self.fallback = fallback
        }

        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            commands.append(arguments)
            return results.isEmpty ? fallback : results.removeFirst()
        }
    }
}
