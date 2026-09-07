/// Bound restarts across the whole disconnected period, including transitions
/// between unavailable and incompatible responses. Only a valid snapshot resets it.
struct AutomaticServiceRecovery {
    private(set) var attempts = 0

    mutating func beginAttempt() -> Bool {
        guard attempts < 2 else { return false }
        attempts += 1
        return true
    }

    mutating func didConnect() {
        attempts = 0
    }
}
