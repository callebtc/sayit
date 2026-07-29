import Foundation

actor APIRateLimiter {
    private var windows: [String: RateLimitWindow] = [:]
    private let clock = ContinuousClock()

    func consume(key: String, limit: Int) -> Bool {
        let now = clock.now
        var window = windows[key] ?? RateLimitWindow(startedAt: now, count: 0)
        if window.startedAt.duration(to: now) >= .seconds(60) {
            window = RateLimitWindow(startedAt: now, count: 0)
        }
        guard window.count < limit else {
            windows[key] = window
            return false
        }
        window.count += 1
        windows[key] = window
        return true
    }
}
