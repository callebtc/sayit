import Foundation

struct RateLimitWindow: Sendable {
    var startedAt: ContinuousClock.Instant
    var count: Int
}
