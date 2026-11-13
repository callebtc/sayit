import Foundation
import SayItProtocol
import Testing
@testable import SayIt

@Suite("Service connection lifecycle")
@MainActor
struct ServiceConnectionLifecycleTests {
    @Test("Suspension drains requests, backoff and grace, then prevents all effects", arguments: ["request", "backoff", "grace"])
    func suspension(_ position: String) async throws {
        let f = ConnectionFixture()
        if position == "backoff" { f.registration.requiresApproval = true }
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        if position != "request" {
            f.transport.fail(0)
            await f.until { f.clock.sleeps.contains(position == "grace" ? 1 : 0.25) }
        }
        let deadline = f.clock.date.addingTimeInterval(15)
        try await f.advancing { try await f.connection.suspend(until: deadline) }
        let outputs = f.outputs.count
        let sends = f.transport.requests.count
        let effects = f.registration.effects
        do { _ = try await f.connection.send(.clear); Issue.record("Suspended send escaped") }
        catch { #expect(error is CancellationError) }
        do { try await f.connection.refresh(); Issue.record("Suspended refresh escaped") }
        catch { #expect(error is CancellationError) }
        await f.connection.restart()
        await f.connection.setEnabled(true)
        f.clock.advance(100)
        await f.settle()
        #expect(f.outputs.count == outputs)
        #expect(f.transport.requests.count == sends)
        #expect(f.registration.effects == effects)
        await f.connection.start()
        await f.until { f.transport.requests.count == sends + 1 }
        #expect(f.registration.effects.last == "ensure")
        await f.connection.stop()
    }

    @Test("Deadline expiry retains canceled restart and resume joins it before reopening")
    func resumeWaitsForCanceledRestart() async throws {
        let f = ConnectionFixture()
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let repair = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        let deadline = f.clock.date.addingTimeInterval(1)
        do {
            try await f.advancing { try await f.connection.suspend(until: deadline) }
            Issue.record("Suspension acknowledged undrained registration")
        } catch { #expect(error is UpdateTaskBarrier.BarrierError) }
        let effects = f.registration.effects
        var resumed = false
        let resume = Task { await f.connection.start(); resumed = true }
        await f.settle()
        #expect(!resumed)
        #expect(f.registration.effects == effects)
        do { try await f.connection.refresh(); Issue.record("Gate reopened before drain") }
        catch { #expect(error is CancellationError) }
        f.registration.releaseRestart()
        await repair.value
        await resume.value
        await f.until { f.transport.requests.count == 2 }
        #expect(resumed)
        #expect(f.registration.effects == ["ensure", "restart", "ensure"])
        #expect(f.connection.state == .connecting)
        await f.connection.stop()
    }

    @Test("Stop joins a restart before returning and cannot be resumed")
    func terminalStop() async {
        let f = ConnectionFixture()
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let repair = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        var stopped = false
        let stop = Task { await f.connection.stop(); stopped = true }
        await f.settle()
        #expect(!stopped)
        f.registration.releaseRestart()
        await repair.value
        await stop.value
        let outputs = f.outputs.count
        let sends = f.transport.requests.count
        let effects = f.registration.effects
        await f.connection.start()
        await f.connection.restart()
        await f.connection.setEnabled(true)
        await f.connection.stop()
        do { try await f.connection.refresh(); Issue.record("Stopped refresh escaped") }
        catch { #expect(error is CancellationError) }
        f.clock.advance(100)
        await f.settle()
        #expect(f.outputs.count == outputs)
        #expect(f.transport.requests.count == sends)
        #expect(f.registration.effects == effects)
    }

    @Test("Repeated suspension and disabled resume do not register or reconnect")
    func disabledResume() async throws {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        await f.connection.setEnabled(false)
        let deadline = f.clock.date.addingTimeInterval(15)
        try await f.advancing { try await f.connection.suspend(until: deadline) }
        try await f.advancing { try await f.connection.suspend(until: deadline) }
        let effects = f.registration.effects
        let sends = f.transport.requests.count
        await f.connection.start()
        await f.connection.start()
        f.clock.advance(10)
        await f.settle()
        #expect(f.registration.effects == effects)
        #expect(f.transport.requests.count == sends)
        #expect(f.connection.state == .disabled)
        await f.connection.stop()
    }
}
