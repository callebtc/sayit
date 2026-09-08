import Foundation

/// Reminder policy is independent of Sparkle's check scheduling.
struct UpdatePreferences {
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    var automaticallyChecks: Bool {
        defaults.object(forKey: "checkForUpdates") as? Bool ?? true
    }

    var mayRemind: Bool {
        guard automaticallyChecks else { return false }
        guard let deadline = defaults.object(forKey: "updateReminderAfter") as? Date else {
            return true
        }
        return now() >= deadline
    }

    func remindLater() {
        defaults.set(now().addingTimeInterval(86_400), forKey: "updateReminderAfter")
    }

    func migrate() {
        guard !defaults.bool(forKey: "sparklePreferencesMigrated") else { return }
        defaults.set(automaticallyChecks, forKey: "SUEnableAutomaticChecks")
        if let date = defaults.object(forKey: "lastUpdateCheck") as? Date {
            defaults.set(date, forKey: "SULastCheckTime")
        }
        defaults.set(true, forKey: "sparklePreferencesMigrated")
    }
}
