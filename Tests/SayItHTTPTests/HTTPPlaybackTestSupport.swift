import Foundation
import SayItCore
@testable import SayItBackend

@MainActor
final class HeadlessPlaybackAudioOutput: PlaybackAudioOutput {
    var onConfigurationChange: (@MainActor @Sendable () -> Void)?
    private(set) var isPlaying = false

    func configureGraph(sampleRate _: Double) throws {}
    func ensureEngineRunning() throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func stopPlayer() { isPlaying = false }
    func pauseEngine() { isPlaying = false }
    func setVolume(_: Float) {}
    func renderedPosition() -> PlaybackRenderPosition? { nil }

    func scheduleBuffer(
        _: [Float],
        sampleRate _: Double,
        completion _: (@MainActor @Sendable () -> Void)?
    ) throws {}

    func openAudioFile(
        at _: URL,
        chunkFrameCount _: Int
    ) throws -> any PlaybackAudioFileReading {
        throw PlaybackError.unsupportedAudioFile
    }
}

@MainActor
final class HeadlessPlaybackMediaSession: PlaybackMediaSession {
    func publishNowPlaying(_: PlaybackNowPlayingInfo) {}
    func clearNowPlaying() {}
    func configureRemoteCommands(
        supportedPlaybackRates _: [Double],
        backwardSkipInterval _: TimeInterval,
        forwardSkipInterval _: TimeInterval,
        handler _: @escaping @MainActor @Sendable (PlaybackRemoteCommand) -> Void
    ) {}
    func setBackwardSkipInterval(_: TimeInterval) {}
    func setForwardSkipInterval(_: TimeInterval) {}
}

@MainActor
func makeHeadlessPlaybackController() -> PlaybackController {
    PlaybackController(
        audioOutput: HeadlessPlaybackAudioOutput(),
        mediaSession: HeadlessPlaybackMediaSession(),
        clock: LivePlaybackClock()
    )
}

@MainActor
func seedStoredAudio(
    on controller: PlaybackController,
    duration: Double = 20,
    paused: Bool = true
) throws {
    let sampleRate = 24_000.0
    let frameCount = Int((sampleRate * duration).rounded())
    let samples = (0..<frameCount).map { frame in
        Float(0.1 * sin(2 * .pi * 220 * Double(frame) / sampleRate))
    }
    let id = UUID()
    controller.prepare(
        requestID: id,
        title: "Headless HTTP Fixture",
        estimatedDuration: duration,
        modelID: nil
    )
    try controller.enqueue(
        AudioChunk(
            requestID: id,
            index: 0,
            samples: samples,
            sampleRate: sampleRate,
            startsParagraph: false
        )
    )
    controller.finishBuffering()
    if paused {
        controller.pause()
    }
}
