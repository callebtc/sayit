import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@MainActor
final class ScriptedPlaybackAudioFile: PlaybackAudioFileReading {
    let sampleRate: Double
    private var chunks: [[Float]]
    private var nextChunkIndex = 0
    private let chunkReadFailure: (index: Int, error: any Error)?

    init(
        sampleRate: Double,
        chunks: [[Float]],
        chunkReadFailure: (index: Int, error: any Error)? = nil
    ) {
        self.sampleRate = sampleRate
        self.chunks = chunks
        self.chunkReadFailure = chunkReadFailure
    }

    func readNextChunk() throws -> [Float]? {
        if let chunkReadFailure, nextChunkIndex == chunkReadFailure.index {
            throw chunkReadFailure.error
        }
        guard nextChunkIndex < chunks.count else { return nil }
        let chunk = chunks[nextChunkIndex]
        nextChunkIndex += 1
        return chunk
    }
}

@MainActor
final class ScriptedPlaybackAudioOutput: PlaybackAudioOutput {
    struct ScheduledBuffer {
        let samples: [Float]
        let sampleRate: Double
        let completion: (@MainActor @Sendable () -> Void)?
    }

    var onConfigurationChange: (@MainActor @Sendable () -> Void)?
    private(set) var isPlaying = false
    private(set) var volume: Float = 1
    private(set) var configuredSampleRates: [Double] = []
    private(set) var stopPlayerCount = 0
    private(set) var pauseEngineCount = 0
    private(set) var scheduledBuffers: [ScheduledBuffer] = []
    private(set) var activeBuffers: [ScheduledBuffer] = []

    var renderedSamplePosition: PlaybackRenderPosition?
    var configureGraphOutcomes: [Result<Void, any Error>] = []
    var ensureEngineRunningOutcomes: [Result<Void, any Error>] = []
    var scheduleBufferError: (any Error)?
    var fileOpeners: [URL: () throws -> any PlaybackAudioFileReading] = [:]

    var totalScheduledSampleCount: Int {
        scheduledBuffers.reduce(0) { $0 + $1.samples.count }
    }

    var allScheduledSamples: [Float] {
        scheduledBuffers.flatMap(\.samples)
    }

    func configureGraph(sampleRate: Double) throws {
        if !configureGraphOutcomes.isEmpty {
            try configureGraphOutcomes.removeFirst().get()
        }
        configuredSampleRates.append(sampleRate)
    }

    func ensureEngineRunning() throws {
        if !ensureEngineRunningOutcomes.isEmpty {
            try ensureEngineRunningOutcomes.removeFirst().get()
        }
    }

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func stopPlayer() {
        isPlaying = false
        stopPlayerCount += 1
        renderedSamplePosition = nil
        activeBuffers.removeAll(keepingCapacity: false)
    }

    func pauseEngine() {
        isPlaying = false
        pauseEngineCount += 1
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
    }

    func renderedPosition() -> PlaybackRenderPosition? {
        guard isPlaying else { return nil }
        return renderedSamplePosition
    }

    func scheduleBuffer(
        _ samples: [Float],
        sampleRate: Double,
        completion: (@MainActor @Sendable () -> Void)?
    ) throws {
        if let scheduleBufferError {
            throw scheduleBufferError
        }
        let buffer = ScheduledBuffer(
            samples: samples,
            sampleRate: sampleRate,
            completion: completion
        )
        scheduledBuffers.append(buffer)
        activeBuffers.append(buffer)
    }

    func openAudioFile(
        at url: URL,
        chunkFrameCount: Int
    ) throws -> any PlaybackAudioFileReading {
        _ = chunkFrameCount
        if let opener = fileOpeners[url] {
            return try opener()
        }
        throw PlaybackError.unsupportedAudioFile
    }

    @discardableResult
    func completeNextBuffer() -> Bool {
        guard !activeBuffers.isEmpty else { return false }
        let buffer = activeBuffers.removeFirst()
        buffer.completion?()
        return true
    }

    func completeAllBuffers() {
        while completeNextBuffer() {}
    }

    func emitConfigurationChange() {
        onConfigurationChange?()
    }
}

@MainActor
final class ScriptedPlaybackMediaSession: PlaybackMediaSession {
    private(set) var publishedInfos: [PlaybackNowPlayingInfo] = []
    private(set) var clearNowPlayingCount = 0
    private(set) var supportedPlaybackRates: [Double] = []
    private(set) var backwardSkipInterval: TimeInterval?
    private(set) var forwardSkipInterval: TimeInterval?

    private var handler: (@MainActor @Sendable (PlaybackRemoteCommand) -> Void)?

    func publishNowPlaying(_ info: PlaybackNowPlayingInfo) {
        publishedInfos.append(info)
    }

    func clearNowPlaying() {
        clearNowPlayingCount += 1
    }

    func configureRemoteCommands(
        supportedPlaybackRates: [Double],
        backwardSkipInterval: TimeInterval,
        forwardSkipInterval: TimeInterval,
        handler: @escaping @MainActor @Sendable (PlaybackRemoteCommand) -> Void
    ) {
        self.supportedPlaybackRates = supportedPlaybackRates
        self.backwardSkipInterval = backwardSkipInterval
        self.forwardSkipInterval = forwardSkipInterval
        self.handler = handler
    }

    func setBackwardSkipInterval(_ interval: TimeInterval) {
        backwardSkipInterval = interval
    }

    func setForwardSkipInterval(_ interval: TimeInterval) {
        forwardSkipInterval = interval
    }

    func sendRemoteCommand(_ command: PlaybackRemoteCommand) {
        handler?(command)
    }
}

@MainActor
final class VirtualPlaybackClock: PlaybackClock {
    private struct PendingSleep {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var now: ContinuousClock.Instant = ContinuousClock.now
    private(set) var sleepDurations: [Duration] = []
    private(set) var cancelledSleepDurations: [Duration] = []
    private var pendingSleeps: [PendingSleep] = []

    var pendingSleepCount: Int {
        pendingSleeps.count
    }

    var pendingSleepDurations: [Duration] {
        pendingSleeps.map(\.duration)
    }

    func sleep(for duration: Duration) async throws {
        sleepDurations.append(duration)
        let id = UUID()
        let deadline = now.advanced(by: max(duration, .zero))
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingSleeps.append(
                    PendingSleep(
                        id: id,
                        deadline: deadline,
                        duration: duration,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelSleep(id: id)
            }
        }
    }

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        let ready = pendingSleeps
            .filter { $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
        pendingSleeps.removeAll { $0.deadline <= now }
        for item in ready {
            item.continuation.resume()
        }
    }

    func failEarliestSleep(with error: any Error) -> Bool {
        guard !pendingSleeps.isEmpty else { return false }
        let earliest = pendingSleeps.removeFirst()
        earliest.continuation.resume(throwing: error)
        return true
    }

    private func cancelSleep(id: UUID) {
        guard let index = pendingSleeps.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = pendingSleeps.remove(at: index)
        cancelledSleepDurations.append(removed.duration)
        removed.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class PlaybackControllerFixture {
    let audioOutput = ScriptedPlaybackAudioOutput()
    let mediaSession = ScriptedPlaybackMediaSession()
    let clock = VirtualPlaybackClock()
    let controller: PlaybackController

    private(set) var failures: [String] = []
    private(set) var externalControlCount = 0
    private(set) var stateChanges: [PlaybackState] = []

    init() {
        controller = PlaybackController(
            audioOutput: audioOutput,
            mediaSession: mediaSession,
            clock: clock
        )
        controller.onFailure = { [weak self] message in
            self?.failures.append(message)
        }
        controller.onExternalControl = { [weak self] in
            self?.externalControlCount += 1
        }
        controller.onStateChange = { [weak self] state in
            self?.stateChanges.append(state)
        }
    }

    func makeTone(
        sampleRate: Double = 24_000,
        duration: Double,
        frequency: Double = 220
    ) -> [Float] {
        let count = Int((sampleRate * duration).rounded())
        guard count > 0 else { return [] }
        let periodFrames = max(Int(sampleRate.rounded()), 1)
        let cycleCount = min(count, periodFrames)
        let base = (0..<cycleCount).map { frame in
            Float(0.1 * sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
        if count == cycleCount {
            return base
        }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        while samples.count < count {
            let remaining = count - samples.count
            samples.append(contentsOf: base.prefix(remaining))
        }
        return samples
    }

    func enqueue(
        requestID: UUID,
        duration: Double,
        sampleRate: Double = 24_000,
        index: Int = 0,
        startsParagraph: Bool = false
    ) throws {
        try controller.enqueue(
            AudioChunk(
                requestID: requestID,
                index: index,
                samples: makeTone(sampleRate: sampleRate, duration: duration),
                sampleRate: sampleRate,
                startsParagraph: startsParagraph
            )
        )
    }

    func settle() async {
        for _ in 0..<25 {
            await Task.yield()
        }
    }

    func until(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record(
            "Playback condition did not settle",
            sourceLocation: sourceLocation
        )
    }

    func advance(by duration: Duration) async {
        clock.advance(by: duration)
        await settle()
    }
}
