import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

// Uses the real output graph, muted. Opt in on a Mac with an audio output device.
@Suite("Time-stretched playback integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SAYIT_PLAYBACK_INTEGRATION"] == "1"))
@MainActor
struct TimeStretchPlaybackTests {
    private func enqueue(_ playback: PlaybackController, id: UUID, duration: Double, index: Int = 0) throws {
        let samples = (0..<Int(24_000 * duration)).map {
            Float(0.1 * sin(2 * .pi * 220 * Double($0) / 24_000))
        }
        try playback.enqueue(AudioChunk(requestID: id, index: index, samples: samples,
                                        sampleRate: 24_000, startsParagraph: false))
    }

    private func waitUntilFinished(_ playback: PlaybackController, timeout: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while playback.state != .finished && playback.state != .failed && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.state == .finished)
        #expect(playback.failureMessage == nil)
    }

    @Test("Real output graph finishes at the requested speed", arguments: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
    func duration(rate: Double) async throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0
        playback.rate = rate
        let id = UUID()
        playback.prepare(requestID: id, title: "DSP integration fixture", estimatedDuration: 1, modelID: nil)
        try enqueue(playback, id: id, duration: 1)
        let start = ContinuousClock.now
        playback.finishBuffering()
        try await waitUntilFinished(playback, timeout: 1 / rate + 2)
        let wall = start.duration(to: .now)
        #expect(wall > .seconds(1 / rate - 0.2))
        #expect(wall < .seconds(1 / rate + 0.75))
        #expect(abs(playback.elapsed - 1) < 0.001)
    }

    @Test("Speed changes, paused seeks and replay preserve source position")
    func controls() async throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0
        playback.rate = 0.5
        let id = UUID()
        playback.prepare(requestID: id, title: "DSP control fixture", estimatedDuration: 2, modelID: nil)
        try enqueue(playback, id: id, duration: 2)
        playback.finishBuffering()
        try await Task.sleep(for: .milliseconds(300))
        let before = playback.elapsed
        playback.rate = 2
        #expect(playback.state == .playing)
        #expect(abs(playback.elapsed - before) < 0.15)
        playback.pause()
        #expect(playback.state == .paused)
        playback.rate = 0.75
        #expect(playback.state == .paused)
        playback.seek(to: 1.5)
        #expect(abs(playback.elapsed - 1.5) < 0.001)
        playback.play()
        try await waitUntilFinished(playback, timeout: 2)
        playback.rate = 2
        playback.play()
        try await waitUntilFinished(playback, timeout: 3)
    }

    @Test("Progressive underruns retain the delayed audio and completion tail")
    func progressive() async throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0
        playback.rate = 1.5
        let id = UUID()
        playback.prepare(requestID: id, title: "DSP progressive fixture", estimatedDuration: 1, modelID: nil)
        try enqueue(playback, id: id, duration: 0.5)
        playback.play()
        try await Task.sleep(for: .milliseconds(600))
        #expect(playback.state == .buffering)
        #expect(playback.elapsed < playback.generatedDuration)
        try enqueue(playback, id: id, duration: 0.5, index: 1)
        playback.finishBuffering()
        try await waitUntilFinished(playback, timeout: 2)
        #expect(abs(playback.elapsed - 1) < 0.001)
    }

    @Test("Long playback replenishes the scheduling horizon")
    func schedulingHorizon() async throws {
        let playback = PlaybackController()
        defer { playback.stop() }
        playback.volume = 0
        playback.rate = 2
        let id = UUID()
        playback.prepare(requestID: id, title: "DSP horizon fixture", estimatedDuration: 13, modelID: nil)
        try enqueue(playback, id: id, duration: 13)
        playback.finishBuffering()
        try await waitUntilFinished(playback, timeout: 9)
        #expect(abs(playback.elapsed - 13) < 0.001)
    }
}
