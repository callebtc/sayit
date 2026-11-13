import Foundation
import Testing
@testable import SayIt

@Suite("Service connection disable handoff")
@MainActor
struct ServiceConnectionDisableHandoffTests {
    @Test("Suspension preserves a disable requested while restart is draining")
    func disableSurvivesSuccessfulUpdateHandoff() async throws {
        let f = ConnectionFixture()
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let repair = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        let disable = Task { await f.connection.setEnabled(false) }
        await f.until { f.connection.state == .disabled }
        let deadline = f.clock.date.addingTimeInterval(15)
        let suspension = Task { try await f.connection.suspend(until: deadline) }
        await f.until { f.clock.sleeps.contains(0.05) }
        f.registration.releaseRestart()
        await repair.value
        await disable.value
        try await f.advancing { try await suspension.value }
        await f.connection.stop()
        #expect(f.registration.isUserDisabled)
        let relaunched = ServiceConnection(
            transport: f.transport, registration: f.registration,
            applicationVersion: "1.0", clock: f.clock.adapter
        )
        await relaunched.start()
        #expect(relaunched.state == .disabled)
        await relaunched.stop()
    }
}
