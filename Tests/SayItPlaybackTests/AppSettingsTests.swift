import Foundation
import Testing
@testable import SayIt

@Suite("App settings")
struct AppSettingsTests {
    @Test("Speaking pace persists as a typed setting")
    @MainActor
    func speakingPacePersists() throws {
        let suiteName = "SayItTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.speakingPace == .natural)

        settings.speakingPace = .fast

        let restoredSettings = AppSettings(defaults: defaults)
        #expect(restoredSettings.speakingPace == .fast)
    }
}
