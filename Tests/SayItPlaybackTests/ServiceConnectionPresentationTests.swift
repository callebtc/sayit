import Testing
@testable import SayIt

@Suite("Service connection presentation")
struct ServiceConnectionPresentationTests {
    @Test("Recovery presents progress while terminal failures expose repair controls")
    func recoveryPresentation() {
        #expect(ServiceConnectionState.recovering.showsRepair)
        #expect(ServiceConnectionState.recovering.label == "Reconnecting")
        #expect(ServiceConnectionState.updateRequired.showsRepair)
        #expect(!ServiceConnectionState.online(version: "1.0").showsRepair)
    }
}
