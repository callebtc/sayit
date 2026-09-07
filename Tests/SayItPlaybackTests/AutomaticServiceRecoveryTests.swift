import SayItProtocol
import Testing
@testable import SayIt

@Suite("Automatic service recovery")
struct AutomaticServiceRecoveryTests {
    @Test("Repeated incompatible or unavailable responses cannot create a restart loop")
    func boundedUntilHealthy() {
        var recovery = AutomaticServiceRecovery()
        let first = recovery.beginAttempt()
        let second = recovery.beginAttempt()
        #expect(first)
        #expect(second)
        for _ in 0..<10 {
            let anotherAttempt = recovery.beginAttempt()
            #expect(!anotherAttempt)
        }
        // Registration alone does not replenish the budget. A valid snapshot does.
        recovery.didConnect()
        let afterConnecting = recovery.beginAttempt()
        #expect(afterConnecting)
    }

    @Test("A matching service snapshot is required before recovery succeeds")
    func validatesReplacement() throws {
        try AppState.validateServiceSnapshot(
            snapshot(version: "1.0"), applicationVersion: "1.0"
        )
        #expect(throws: ServiceFailure.self) {
            try AppState.validateServiceSnapshot(
                snapshot(version: "0.9"), applicationVersion: "1.0"
            )
        }
        #expect(throws: ServiceFailure.self) {
            try AppState.validateServiceSnapshot(
                snapshot(version: "1.0", protocolVersion: -1),
                applicationVersion: "1.0"
            )
        }
    }

    @Test("Recovery presents progress while terminal failures expose repair controls")
    func recoveryPresentation() {
        #expect(ServiceConnectionState.recovering.showsRepair)
        #expect(ServiceConnectionState.recovering.label == "Reconnecting")
        #expect(ServiceConnectionState.updateRequired.showsRepair)
        #expect(!ServiceConnectionState.online(version: "1.0").showsRepair)
    }

    private func snapshot(
        version: String,
        protocolVersion: Int = SayItProtocolVersion.current
    ) -> ServiceSnapshot {
        ServiceSnapshot(
            protocolVersion: protocolVersion, serviceVersion: version, revision: 1,
            statusText: "Ready", lastError: nil, activeJob: nil, queuedJobs: [],
            playback: PlaybackSnapshot(), download: nil, installedModelIDs: [],
            settings: BackendSettingsSnapshot(), modelsRevision: 0,
            historyRevision: 0, diagnosticsRevision: 0
        )
    }
}
