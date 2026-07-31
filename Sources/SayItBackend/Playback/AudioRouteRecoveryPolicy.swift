import Foundation

struct AudioRouteRecoveryPolicy {
    static let debounceDelay: Duration = .milliseconds(150)
    static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500)
    ]

    static func stableAnchor(
        lastRendered: TimeInterval,
        fallback: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let rendered = lastRendered.isFinite ? lastRendered : 0
        let fallback = fallback.isFinite ? fallback : 0
        let duration = duration.isFinite ? max(duration, 0) : 0
        return min(max(rendered, fallback, 0), duration)
    }

    static func canRetry(_ error: Error) -> Bool {
        switch error {
        case PlaybackError.noOutputDevice,
             PlaybackError.couldNotStartEngine:
            true
        default:
            false
        }
    }
}
