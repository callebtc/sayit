import Foundation
import SayItCore
import Testing
@testable import SayIt

@Suite("Registered service startup")
@MainActor
struct RegisteredServiceStartupTests {
    @Test("An agent from a previous app process is restarted after publishing its new owner")
    func replacesPreviousOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        ParentProcessFile.write(pid: 101, in: directory)
        var restartCount = 0
        try await RegisteredServiceStartup.ensureRunning(
            isEnabled: true,
            parentProcessMatches: {
                ParentProcessFile.readPID(from: directory) == 202
            },
            writeParentProcess: {
                ParentProcessFile.write(pid: 202, in: directory)
            },
            restart: {
                #expect(ParentProcessFile.readPID(from: directory) == 202)
                restartCount += 1
            }
        )
        #expect(restartCount == 1)
    }

    @Test("An enabled service owned by this app is reused")
    func reusesCurrentOwner() async throws {
        var restarted = false
        try await RegisteredServiceStartup.ensureRunning(
            isEnabled: true,
            parentProcessMatches: { true },
            writeParentProcess: {},
            restart: { restarted = true }
        )
        #expect(!restarted)
    }

    @Test("An unregistered service starts even if the owner file matches")
    func startsUnregisteredService() async throws {
        var restarted = false
        try await RegisteredServiceStartup.ensureRunning(
            isEnabled: false,
            parentProcessMatches: { true },
            writeParentProcess: {},
            restart: { restarted = true }
        )
        #expect(restarted)
    }

    @Test("Registration failures reach the caller")
    func reportsRegistrationFailure() async {
        await #expect(throws: CocoaError.self) {
            try await RegisteredServiceStartup.ensureRunning(
                isEnabled: true,
                parentProcessMatches: { false },
                writeParentProcess: {},
                restart: { throw CocoaError(.fileWriteNoPermission) }
            )
        }
    }
}
