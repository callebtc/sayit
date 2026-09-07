import Foundation
import Testing

struct UpdatePreferencesTests {
    @Test func migrationPreservesOptOutAndLastCheckOnlyOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "UpdateTests.\(UUID().uuidString)"))
        let date = Date(timeIntervalSince1970: 100)
        defaults.set(false, forKey: "checkForUpdates")
        defaults.set(date, forKey: "lastUpdateCheck")
        let preferences = UpdatePreferences(defaults: defaults)
        preferences.migrate()
        #expect(!defaults.bool(forKey: "SUEnableAutomaticChecks"))
        #expect(defaults.object(forKey: "SULastCheckTime") as? Date == date)
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        preferences.migrate()
        #expect(defaults.bool(forKey: "SUEnableAutomaticChecks"))
    }

    @Test func freshInstallsCheckAutomatically() throws {
        let defaults = try #require(UserDefaults(suiteName: "UpdateTests.\(UUID().uuidString)"))
        let preferences = UpdatePreferences(defaults: defaults)
        preferences.migrate()
        #expect(defaults.bool(forKey: "SUEnableAutomaticChecks"))
        #expect(preferences.mayRemind)
    }

    @Test func laterPersistsForExactlyOneDayAcrossInstances() throws {
        let defaults = try #require(UserDefaults(suiteName: "UpdateTests.\(UUID().uuidString)"))
        let start = Date(timeIntervalSince1970: 100)
        UpdatePreferences(defaults: defaults, now: { start }).remindLater()
        #expect(!UpdatePreferences(defaults: defaults, now: { start.addingTimeInterval(86_399) }).mayRemind)
        #expect(UpdatePreferences(defaults: defaults, now: { start.addingTimeInterval(86_400) }).mayRemind)
        defaults.set(false, forKey: "checkForUpdates")
        #expect(!UpdatePreferences(defaults: defaults, now: { start.addingTimeInterval(90_000) }).mayRemind)
    }
}
