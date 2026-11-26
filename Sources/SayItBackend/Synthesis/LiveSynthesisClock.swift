struct LiveSynthesisClock: SynthesisClock {
    var now: ContinuousClock.Instant {
        ContinuousClock.now
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
