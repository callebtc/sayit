import Foundation
import SayItProtocol
import Testing
@testable import SayIt

@Suite("App connection lifecycle")
@MainActor
struct AppConnectionLifecycleTests {
    @Test("Installed updater preparation callback shares one deadline through connection drain and both helpers")
    func sharedUpdateDeadline() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let restart = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        let started = f.clock.date
        h.app.settings.speakingPace = .fast
        h.app.updates.receive(
            UpdateOffer(build: "20", version: "1.2.0", notesURL: nil), userInitiated: true
        ) { _ in }
        h.app.updates.updateNow()
        var prepared = false
        let preparation = Task {
            let choice = await withCheckedContinuation { continuation in
                h.app.updates.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
            }
            #expect(choice == .install)
            prepared = true
        }
        await f.until { h.app.isPreparingUpdate && f.clock.sleeps.contains(0.05) }
        #expect(h.helperEffects == ["remember selection"])
        #expect(!prepared)
        f.clock.advance(7)
        h.selectionStopDuration = 4
        f.registration.releaseRestart()
        await restart.value
        try await f.advancing { await preparation.value }
        #expect(h.app.isPreparedForUpdate)
        #expect(h.deadlines == [started.addingTimeInterval(15), started.addingTimeInterval(15)])
        #expect(h.helperEffects == ["remember selection", "stop selection for update", "stop background for update"])
        let sends = f.transport.requests.count
        let registrations = f.registration.effects
        h.app.restartBackgroundService()
        h.app.setBackgroundServiceEnabled(true)
        h.app.clearCurrentSpeech()
        f.clock.advance(100)
        await f.settle()
        #expect(f.transport.requests.count == sends)
        #expect(f.registration.effects == registrations)
        #expect(h.app.errorMessage == nil)
        await h.app.terminateBackgroundServiceForQuit()
    }

    @Test("Updater recovery after expired suspension joins old registration before restoring helpers")
    func timedOutUpdateRecovery() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let restart = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        do {
            try await f.advancing { try await h.app.updates.prepareForInstallation() }
            Issue.record("Update acknowledged a running restart")
        } catch { #expect(error is UpdateTaskBarrier.BarrierError) }
        #expect(h.deadlines.isEmpty)
        var recovered = false
        let recovery = Task {
            await h.app.updates.recoverFromInstallationFailure()
            recovered = true
        }
        await f.settle()
        #expect(!recovered)
        #expect(h.app.isPreparingUpdate)
        #expect(!h.helperEffects.contains("restore selection"))
        f.registration.releaseRestart()
        await restart.value
        await recovery.value
        #expect(!h.app.isPreparingUpdate)
        #expect(!h.app.isPreparedForUpdate)
        #expect(h.helperEffects.last == "restore selection")
        await f.until { f.transport.requests.count == 2 }
        await h.app.terminateBackgroundServiceForQuit()
    }

    @Test("Canceled installation recovery respects disabled preference")
    func disabledUpdateRecovery() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        await f.connection.setEnabled(false)
        try await f.advancing { try await h.app.updates.prepareForInstallation() }
        let registrations = f.registration.effects
        let sends = f.transport.requests.count
        await h.app.updates.recoverFromInstallationFailure()
        f.clock.advance(10)
        await f.settle()
        #expect(f.registration.effects == registrations)
        #expect(f.transport.requests.count == sends)
        #expect(h.app.serviceConnection == .disabled)
        #expect(h.helperEffects.last == "restore selection")
        await h.app.terminateBackgroundServiceForQuit()
    }

    @Test("Time spent terminating selection consumes the background helper's existing deadline")
    func helperDeadlineIsNotRenewed() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        h.selectionStopDuration = 16
        do {
            try await f.advancing { try await h.app.updates.prepareForInstallation() }
            Issue.record("Helper termination received a renewed deadline")
        } catch { #expect(error is UpdateTaskBarrier.BarrierError) }
        #expect(h.deadlines.count == 1)
        #expect(!h.helperEffects.contains("stop background for update"))
        #expect(!h.app.isPreparedForUpdate)
        await h.app.updates.recoverFromInstallationFailure()
        await h.app.terminateBackgroundServiceForQuit()
    }

    @Test("Quit entry point joins connection work before physical helper termination")
    func quitJoinsConnection() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        f.registration.holdsRestart = true
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        let restart = Task { await f.connection.restart() }
        await f.until { f.registration.restartCount == 1 }
        var quit = false
        let termination = Task { await h.app.terminateBackgroundServiceForQuit(); quit = true }
        await f.settle()
        #expect(!quit)
        #expect(h.helperEffects.isEmpty)
        f.registration.releaseRestart()
        await restart.value
        await termination.value
        #expect(h.helperEffects == ["stop selection for quit", "stop background for quit"])
        let registrations = f.registration.effects
        let sends = f.transport.requests.count
        await f.connection.start()
        await h.app.updates.recoverFromInstallationFailure()
        f.clock.advance(100)
        await f.settle()
        #expect(f.registration.effects == registrations)
        #expect(f.transport.requests.count == sends)
    }

    @Test("Ancillary cursors reset before replacement snapshots and obsolete list failures stay silent")
    func ancillaryResetAndFreshness() async throws {
        let h = try AppConnectionFixture()
        defer { h.removePreferences() }
        let f = h.connection
        await f.connection.start()
        await f.until { f.transport.requests.count == 1 }
        f.transport.reply(0, .snapshot(connectionSnapshot(revision: 100, ancillaryRevision: 7)))
        await f.until { f.transport.requests.count == 6 }
        let oldLists = f.transport.requests.indices.filter { Self.isAncillary(f.transport.requests[$0]) }
        f.transport.heldRequests.formUnion(oldLists)
        await f.connection.restart()
        await f.advanceUntil { f.transport.requests.count == 7 }
        f.transport.reply(6, .snapshot(connectionSnapshot(revision: 1, ancillaryRevision: 7)))
        await f.until { f.transport.requests.count == 12 }
        let newLists = f.transport.requests.indices.filter { $0 > 6 && Self.isAncillary(f.transport.requests[$0]) }
        #expect(oldLists.count == 4)
        #expect(newLists.count == 4)
        for index in oldLists { f.transport.fail(index) }
        for index in newLists {
            switch f.transport.requests[index] {
            case .models: f.transport.reply(index, .models([]))
            case .history: f.transport.reply(index, .history([]))
            case .diagnostics: f.transport.reply(index, .diagnostics([]))
            case .voices: f.transport.reply(index, .voices([]))
            default: Issue.record("Unexpected ancillary request")
            }
        }
        await f.until { h.app.models.isEmpty }
        #expect(h.app.errorMessage == nil)
        #expect(h.app.serviceConnection == .online(version: "1.0"))
        await h.app.terminateBackgroundServiceForQuit()
    }

    private static func isAncillary(_ command: ServiceCommand) -> Bool {
        switch command {
        case .models, .history, .diagnostics, .voices: true
        default: false
        }
    }
}

@MainActor
private final class AppConnectionFixture {
    let connection = ConnectionFixture()
    let defaults: UserDefaults
    let suiteName: String
    private(set) var app: AppState!
    private(set) var helperEffects: [String] = []
    private(set) var deadlines: [Date] = []
    var selectionStopDuration: TimeInterval = 0

    init() throws {
        let suiteName = "AppConnectionTests.\(UUID().uuidString)"
        self.suiteName = suiteName
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let operations = AppLifecycleOperations(
            clock: connection.clock.adapter,
            rememberSelectionForUpdate: { self.helperEffects.append("remember selection") },
            restoreSelection: { self.helperEffects.append("restore selection") },
            terminateSelectionForUpdate: { deadline in
                self.deadlines.append(deadline)
                self.helperEffects.append("stop selection for update")
                self.connection.clock.advance(self.selectionStopDuration)
                guard self.connection.clock.date < deadline else { throw UpdateTaskBarrier.BarrierError.timedOut }
            },
            terminateBackgroundForUpdate: { deadline in
                self.deadlines.append(deadline)
                self.helperEffects.append("stop background for update")
                guard self.connection.clock.date < deadline else { throw UpdateTaskBarrier.BarrierError.timedOut }
            },
            terminateSelectionForQuit: { self.helperEffects.append("stop selection for quit") },
            terminateBackgroundForQuit: { self.helperEffects.append("stop background for quit") }
        )
        app = AppState(
            connection: connection.connection,
            settings: AppSettings(defaults: defaults),
            updates: UpdateController(
                preferences: UpdatePreferences(defaults: defaults), presentsWindows: false
            ),
            lifecycleOperations: operations
        )
    }

    func removePreferences() {
        defaults.removePersistentDomain(forName: suiteName)
        app = nil
    }
}
