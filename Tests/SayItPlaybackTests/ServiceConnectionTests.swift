import Foundation
import SayItProtocol
import SayItXPC
import Testing
@testable import SayIt

@Suite("Service connection")
@MainActor
struct ServiceConnectionTests {
    @Test("Registration does not report connected before a compatible snapshot")
    func registrationRequiresSnapshot() async throws {
        let fixture = ConnectionFixture()
        await fixture.connection.start()
        await fixture.until { fixture.transport.requests.count == 1 }
        #expect(fixture.connection.state == .connecting)
        fixture.transport.reply(0, .snapshot(connectionSnapshot(revision: 7)))
        await fixture.until { fixture.snapshots.count == 1 }
        #expect(fixture.connection.state == .online(version: "1.0"))
        await fixture.connection.stop()
    }

    @Test("Unavailable and mismatch responses share two attempts, including after manual repair")
    func sharedAutomaticBudget() async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.fail(0)
        await f.advanceUntil { f.transport.requests.count == 2 }
        #expect(f.registration.restartCount == 1)
        f.transport.reply(1, .snapshot(connectionSnapshot(revision: 1, version: "old")))
        await f.advanceUntil { f.transport.requests.count == 3 }
        #expect(f.registration.restartCount == 2)
        f.transport.fail(2)
        await f.advanceUntil { f.transport.requests.count == 4 }
        #expect(f.registration.restartCount == 2)
        #expect(f.connection.state == .offline)
        await f.connection.restart()
        await f.advanceUntil { f.transport.requests.count == 5 }
        #expect(f.registration.restartCount == 3)
        f.transport.reply(4, .snapshot(connectionSnapshot(revision: 1, version: "old")))
        await f.advanceUntil { f.transport.requests.count == 6 }
        #expect(f.registration.restartCount == 3)
        // Only accepting a compatible snapshot replenishes the shared budget.
        f.transport.reply(5, .snapshot(connectionSnapshot(revision: 1)))
        await f.until { f.transport.requests.count == 7 }
        f.transport.fail(6)
        await f.advanceUntil { f.registration.restartCount == 4 }
        await f.connection.stop()
    }

    @Test("Both exact app version and protocol version are required", arguments: [false, true])
    func incompatibleSnapshots(protocolMismatch: Bool) async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.reply(0, .snapshot(connectionSnapshot(
            revision: 100, version: protocolMismatch ? "1.0" : "1.0.1",
            protocolVersion: protocolMismatch ? -1 : SayItProtocolVersion.current
        )))
        await f.until { f.clock.sleeps.contains(2) }
        #expect(f.snapshots.isEmpty)
        #expect(f.connection.state == .recovering)
        await f.connection.stop()
    }

    @Test("Disabled, approval-required and working states suppress automatic restart", arguments: ["disabled", "approval", "working"])
    func restartSuppression(_ mode: String) async {
        let f = ConnectionFixture()
        if mode == "disabled" { f.registration.isUserDisabled = true }
        await f.connection.start()
        if mode != "disabled" {
            await f.until { f.transport.requests.count == 1 }
            f.registration.requiresApproval = mode == "approval"
            f.registration.isWorking = mode == "working"
            f.transport.fail(0)
            await f.until { !f.clock.sleeps.isEmpty }
        } else {
            await f.until { f.clock.sleeps.contains(1) }
            #expect(f.transport.requests.isEmpty)
            #expect(f.connection.state == .disabled)
            #expect(f.registration.effects.isEmpty)
        }
        f.clock.advance(10)
        await f.settle()
        #expect(f.registration.restartCount == 0)
        await f.connection.stop()
    }

    @Test("Disablement during automatic grace cancels repair and enable uses the same route")
    func disableDuringGrace() async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.fail(0)
        await f.until { f.clock.sleeps.contains(1) }
        await f.connection.setEnabled(false)
        let sends = f.transport.requests.count
        f.clock.advance(10)
        await f.settle()
        #expect(f.registration.restartCount == 0)
        #expect(f.registration.effects.last == "disable")
        #expect(f.transport.requests.count == sends)
        #expect(f.connection.state == .disabled)
        await f.connection.setEnabled(true)
        await f.until { f.transport.requests.count > sends }
        #expect(f.registration.effects.last == "enable")
        await f.connection.stop()
    }

    @Test("Approval and working state are checked again after grace", arguments: [false, true])
    func permissionChangesDuringGrace(working: Bool) async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.fail(0)
        await f.until { f.clock.sleeps.contains(1) }
        f.registration.requiresApproval = !working
        f.registration.isWorking = working
        f.clock.advance(1)
        await f.settle()
        #expect(f.registration.restartCount == 0)
        await f.connection.stop()
    }

    @Test("Repair is single flight and blocks polling and explicit refresh")
    func singleRepair() async {
        let f = ConnectionFixture()
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let repair = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        await f.connection.restart()
        do { try await f.connection.refresh(); Issue.record("Refresh ran during repair") }
        catch { #expect(error is CancellationError) }
        f.clock.advance(10)
        await f.settle()
        #expect(f.transport.requests.count == 1)
        #expect(f.registration.restartCount == 1)
        f.registration.releaseRestart()
        await repair.value
        await f.advanceUntil { f.transport.requests.count == 2 }
        #expect(f.connection.state == .recovering)
        await f.connection.stop()
    }

    @Test("Ordinary and ancillary successes and failures from replaced agents are silent", arguments: [ServiceCommand.clear, .models, .history, .diagnostics, .voices(modelID: nil)], [false, true])
    func obsoleteCommands(_ command: ServiceCommand, failure: Bool) async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.heldRequests.insert(1)
        let old = Task { try await f.connection.send(command) }
        await f.until { f.transport.requests.count == 2 }
        await f.connection.restart()
        await f.advanceUntil { f.transport.requests.count == 3 }
        f.transport.reply(2, .snapshot(connectionSnapshot(revision: 1)))
        await f.until { f.snapshots.count == 1 }
        let outputs = f.outputs.count
        let invalidations = f.transport.invalidations
        if failure { f.transport.fail(1) } else { f.transport.reply(1, .accepted) }
        do { _ = try await old.value; Issue.record("Obsolete response escaped") }
        catch { #expect(error is CancellationError) }
        #expect(f.outputs.count == outputs)
        #expect(f.transport.invalidations == invalidations)
        #expect(f.connection.state == .online(version: "1.0"))
        await f.connection.stop()
    }

    @Test("A concurrent refresh makes older snapshot and event successes or failures obsolete", arguments: [false, true], [false, true])
    func concurrentRefresh(events: Bool, failure: Bool) async throws {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        var oldIndex = 0
        if events {
            f.transport.reply(0, .snapshot(connectionSnapshot(revision: 7)))
            await f.until { f.transport.requests.count == 2 }
            oldIndex = 1
        }
        let refresh = Task { try await f.connection.refresh() }
        await f.until { f.transport.requests.count == oldIndex + 2 }
        f.transport.reply(oldIndex + 1, .snapshot(connectionSnapshot(revision: 8)))
        try await refresh.value
        let outputs = f.outputs.count
        if failure {
            f.transport.fail(oldIndex)
        } else if events {
            f.transport.reply(oldIndex, .events([ServiceEvent(id: 100, snapshot: connectionSnapshot(revision: 100))]))
        } else {
            f.transport.reply(oldIndex, .snapshot(connectionSnapshot(revision: 100)))
        }
        await f.until { f.transport.requests.count == oldIndex + 3 }
        #expect(f.outputs.count == outputs)
        #expect(f.transport.invalidations == 0)
        #expect(f.snapshots.last?.revision == 8)
        if case .waitForEvents(let after, _)? = f.transport.requests.last {
            #expect(after == 8)
        } else { Issue.record("Polling did not continue from the accepted cursor") }
        await f.connection.stop()
    }

    @Test("Old command failures after a newer healthy snapshot cannot retire the connection")
    func lateFailureAfterAcceptance() async throws {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let old = Task { try await f.connection.send(.models) }
        await f.until { f.transport.requests.count == 2 }
        f.transport.reply(0, .snapshot(connectionSnapshot(revision: 7)))
        await f.until { f.snapshots.count == 1 }
        f.transport.fail(1)
        do { _ = try await old.value; Issue.record("Old failure escaped") }
        catch { #expect(error is CancellationError) }
        #expect(f.transport.invalidations == 0)
        #expect(f.registration.restartCount == 0)
        #expect(f.connection.state == .online(version: "1.0"))
        await f.connection.stop()
    }

    @Test("Revisions increase within an epoch and may start lower after replacement")
    func revisionAcceptance() async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.reply(0, .snapshot(connectionSnapshot(revision: 7)))
        await f.until { f.transport.requests.count == 2 }
        f.transport.reply(1, .events([ServiceEvent(id: 7, snapshot: connectionSnapshot(revision: 7))]))
        await f.until { f.transport.requests.count == 3 }
        f.transport.reply(2, .events([ServiceEvent(id: 8, snapshot: connectionSnapshot(revision: 6))]))
        await f.until { f.transport.requests.count == 4 }
        #expect(f.snapshots.map(\.revision) == [7])
        f.transport.reply(3, .events([]))
        await f.until { f.transport.requests.count == 5 }
        #expect(f.snapshots.map(\.revision) == [7])
        await f.connection.restart()
        await f.advanceUntil { f.transport.requests.count == 6 }
        f.transport.reply(5, .snapshot(connectionSnapshot(revision: 1)))
        await f.until { f.snapshots.count == 2 }
        #expect(f.snapshots.map(\.revision) == [7, 1])
        // Reset notifications are synchronous and precede replacement data.
        let lastReset = f.outputs.lastIndex { if case .reset = $0 { true } else { false } }
        let lastSnapshot = f.outputs.lastIndex { if case .snapshot = $0 { true } else { false } }
        #expect((lastReset ?? 99) < (lastSnapshot ?? 0))
        await f.connection.stop()
    }

    @Test("Visibility, empty events and timing suffixes preserve one polling loop")
    func cadenceAndPayloads() async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        #expect(f.registration.effects == ["ensure"])
        let chunk = PlaybackTextChunk(textStart: 0, textEnd: 5, audioStart: 0)
        f.transport.reply(0, .snapshot(connectionSnapshot(
            revision: 1, playback: PlaybackSnapshot(spokenText: "first", spokenChunks: [chunk])
        )))
        await f.until { f.transport.requests.count == 2 }
        if case .waitForEvents(_, let interval)? = f.transport.requests.last {
            #expect(interval == 1)
        } else { Issue.record("Expected hidden playback cadence") }
        f.connection.setPlaybackSurfaceVisible(true)
        f.transport.reply(1, .events([ServiceEvent(id: 2, snapshot: connectionSnapshot(
            revision: 2, playback: PlaybackSnapshot(
                spokenChunks: [chunk], includesContent: false,
                includesTiming: true, timingStartIndex: 1
            )
        ))]))
        await f.until { f.transport.requests.count == 3 }
        #expect(f.snapshots.first?.playback.spokenText == "first")
        #expect(f.snapshots.last?.playback.timingStartIndex == 1)
        #expect(f.snapshots.last?.playback.includesContent == false)
        if case .waitForEvents(_, let interval)? = f.transport.requests.last {
            #expect(interval == 0.25)
        } else { Issue.record("Expected visible playback cadence") }
        await f.connection.stop()
    }

    @Test("Unavailable backoff doubles to eight seconds and health resets it")
    func unavailableBackoff() async {
        let f = ConnectionFixture()
        f.registration.requiresApproval = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        for (index, delay) in [0.25, 0.5, 1, 2, 4, 8, 8].enumerated() {
            let sleeps = f.clock.sleeps.count
            f.transport.fail(index)
            await f.until { f.clock.sleeps.count > sleeps }
            #expect(f.clock.sleeps.last == delay)
            f.clock.advance(delay)
            await f.until { f.transport.requests.count == index + 2 }
        }
        f.transport.reply(7, .snapshot(connectionSnapshot(revision: 1)))
        await f.until { f.transport.requests.count == 9 }
        let sleeps = f.clock.sleeps.count
        f.transport.fail(8)
        await f.until { f.clock.sleeps.count > sleeps }
        #expect(f.clock.sleeps.last == 0.25)
        await f.connection.stop()
    }

    @Test("Failed mutations are forwarded once while recovery only synchronizes")
    func mutationsAreNeverReplayed() async {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let command = Task { try await f.connection.send(.clear) }
        await f.until { f.transport.requests.count == 2 }
        f.transport.fail(1)
        do { _ = try await command.value; Issue.record("Failed mutation succeeded") }
        catch { #expect(error is SayItXPCClientError) }
        await f.advanceUntil { f.registration.restartCount == 1 && f.transport.requests.count == 3 }
        let mutations = f.transport.requests.filter { if case .clear = $0 { true } else { false } }
        #expect(mutations.count == 1)
        await f.connection.stop()
    }

    @Test("Business failures retain their response semantics and do not restart")
    func businessFailure() async throws {
        let f = ConnectionFixture()
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let command = Task { try await f.connection.send(.clear) }
        await f.until { f.transport.requests.count == 2 }
        f.transport.reply(1, .failure(ServiceFailure(code: "test.business", message: "Rejected")))
        let response = try await command.value
        if case .failure(let failure) = response {
            #expect(failure.code == "test.business")
        } else { Issue.record("Business failure was reinterpreted") }
        #expect(f.registration.restartCount == 0)
        #expect(f.transport.invalidations == 0)
        await f.connection.stop()
    }

    @Test("A toggle before startup preserves intent without registering before migration")
    func enabledIntentBeforeStart() async {
        let f = ConnectionFixture()
        await f.connection.setEnabled(false)
        #expect(f.registration.effects.isEmpty)
        await f.connection.start()
        await f.until { f.clock.sleeps.contains(1) }
        #expect(f.registration.effects == ["disable"])
        #expect(f.transport.requests.isEmpty)
        #expect(f.connection.state == .disabled)
        await f.connection.setEnabled(true)
        await f.until { f.transport.requests.count == 1 }
        #expect(f.registration.effects == ["disable", "enable"])
        await f.connection.stop()
    }
}
