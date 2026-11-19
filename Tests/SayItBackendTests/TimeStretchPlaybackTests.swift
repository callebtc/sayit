import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

// Uses the real output graph, muted. Opt in on a Mac with an audio output device.
@Suite(
    "Time-stretched playback integration",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "SAYIT_PLAYBACK_INTEGRATION"
        ] == "1"
    )
)
@MainActor
struct TimeStretchPlaybackTests {
    @Test("Live audio output completes muted time-stretched playback")
    func liveOutputSmoke() async throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0
        playback.rate = 1.5
        let id = UUID()
        let samples = (0..<24_000).map { frame in
            Float(0.1 * sin(2 * .pi * 220 * Double(frame) / 24_000))
        }
        playback.prepare(
            requestID: id,
            title: "DSP smoke fixture",
            estimatedDuration: 1,
            modelID: nil
        )
        try playback.enqueue(
            AudioChunk(
                requestID: id,
                index: 0,
                samples: samples,
                sampleRate: 24_000,
                startsParagraph: false
            )
        )
        playback.finishBuffering()

        let deadline = ContinuousClock.now + .seconds(3)
        while playback.state != .finished
            && playback.state != .failed
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.state == .finished)
        #expect(playback.failureMessage == nil)
        #expect(abs(playback.elapsed - 1) < 0.001)
    }
}
