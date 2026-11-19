import Foundation

@MainActor
protocol PlaybackAudioOutput: AnyObject, Sendable {
    var onConfigurationChange: (@MainActor @Sendable () -> Void)? { get set }
    var isPlaying: Bool { get }

    func configureGraph(sampleRate: Double) throws
    func ensureEngineRunning() throws
    func play()
    func pause()
    func stopPlayer()
    func pauseEngine()
    func setVolume(_ volume: Float)
    func renderedPosition() -> PlaybackRenderPosition?
    func scheduleBuffer(
        _ samples: [Float],
        sampleRate: Double,
        completion: (@MainActor @Sendable () -> Void)?
    ) throws
    func openAudioFile(
        at url: URL,
        chunkFrameCount: Int
    ) throws -> any PlaybackAudioFileReading
}
