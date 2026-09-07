import Foundation
import ServiceManagement
import Testing
@testable import SayIt

@Suite("Registered service restart")
@MainActor
struct RegisteredServiceRestartTests {
    @Test("Cleanup precedes unregister and registration waits for the old service to stop")
    func orderedRestart() async throws {
        var status = SMAppService.Status.enabled
        var events: [String] = []
        try await RegisteredServiceStartup.restart(
            status: { status },
            removeConflict: { events.append("cleanup") },
            unregister: { events.append("unregister") },
            register: {
                #expect(status == .notRegistered)
                events.append("register")
                status = .enabled
            },
            wait: {
                events.append("wait")
                status = .notRegistered
            }
        )
        #expect(events == ["cleanup", "unregister", "wait", "register"])
    }

    @Test("An unmanaged job with no registration is cleaned up before registering")
    func unregisteredConflict() async throws {
        var status = SMAppService.Status.notRegistered
        var cleaned = false
        try await RegisteredServiceStartup.restart(
            status: { status },
            removeConflict: { cleaned = true },
            unregister: { Issue.record("No registration to remove") },
            register: {
                #expect(cleaned)
                status = .enabled
            },
            wait: {}
        )
    }

    @Test("Unregister failures cannot masquerade as a successful restart")
    func unregisterFailure() async {
        await #expect(throws: CocoaError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .enabled },
                removeConflict: {},
                unregister: { throw CocoaError(.fileWriteNoPermission) },
                register: { Issue.record("Must not register after failure") },
                wait: {}
            )
        }
    }

    @Test("Timeout stopping an enabled service never skips ahead to registration")
    func unregisterTimeout() async {
        var waits = 0
        await #expect(throws: RegisteredServiceStartup.StartupError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .enabled },
                removeConflict: {},
                unregister: {},
                register: { Issue.record("Must not register before the old service stops") },
                wait: { waits += 1 }
            )
        }
        #expect(waits == 50)
    }

    @Test("A cleanup failure prevents registration")
    func cleanupFailure() async {
        await #expect(throws: CocoaError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .notRegistered },
                removeConflict: { throw CocoaError(.fileWriteNoPermission) },
                unregister: { Issue.record("Cleanup failed") },
                register: { Issue.record("Cleanup failed") },
                wait: {}
            )
        }
    }

    @Test("Revoked approval never triggers cleanup or a registration workaround")
    func respectsApproval() async {
        await #expect(throws: RegisteredServiceStartup.StartupError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .requiresApproval },
                removeConflict: { Issue.record("Must preserve user consent") },
                unregister: { Issue.record("Must preserve user consent") },
                register: { Issue.record("Must preserve user consent") },
                wait: {}
            )
        }
    }

    @Test("Approval revoked during inspection also stops the restart")
    func approvalChangesDuringCleanup() async {
        var status = SMAppService.Status.enabled
        await #expect(throws: RegisteredServiceStartup.StartupError.self) {
            try await RegisteredServiceStartup.restart(
                status: { status },
                removeConflict: { status = .requiresApproval },
                unregister: { Issue.record("Consent was revoked") },
                register: { Issue.record("Consent was revoked") },
                wait: {}
            )
        }
    }

    @Test("Registration errors, approval requests, and registration timeouts reach the caller")
    func registrationFailures() async {
        for result in [SMAppService.Status.notRegistered, .requiresApproval] {
            var status = SMAppService.Status.notRegistered
            await #expect(throws: RegisteredServiceStartup.StartupError.self) {
                try await RegisteredServiceStartup.restart(
                    status: { status },
                    removeConflict: {},
                    unregister: {},
                    register: { status = result },
                    wait: {}
                )
            }
        }
        await #expect(throws: CocoaError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .notRegistered }, removeConflict: {}, unregister: {},
                register: { throw CocoaError(.fileWriteNoPermission) }, wait: {}
            )
        }
    }

    @Test("Cancellation during shutdown cannot start a replacement service")
    func cancellation() async {
        await #expect(throws: CancellationError.self) {
            try await RegisteredServiceStartup.restart(
                status: { .enabled }, removeConflict: {}, unregister: {},
                register: { Issue.record("Must not register after cancellation") },
                wait: { throw CancellationError() }
            )
        }
    }
}
