import AVFoundation
import Foundation
@preconcurrency import MediaPlayer
import Observation
import SayItCore

@MainActor
@Observable
final class PlaybackController: PlaybackControlling {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var timelineTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var sampleRate: Double = 24_000
    private var seekOffset: TimeInterval = 0
    private var requestID: UUID?

    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    var showTitleInNowPlaying = false {
        didSet { updateNowPlaying() }
    }
    var rate: Double = 1 {
        didSet {
            timePitch.rate = Float(rate)
            updateNowPlaying()
        }
    }
    var backwardSkipInterval: TimeInterval = 15 {
        didSet {
            MPRemoteCommandCenter.shared()
                .skipBackwardCommand.preferredIntervals = [
                    NSNumber(value: backwardSkipInterval)
                ]
        }
    }
    var forwardSkipInterval: TimeInterval = 30 {
        didSet {
            MPRemoteCommandCenter.shared()
                .skipForwardCommand.preferredIntervals = [
                    NSNumber(value: forwardSkipInterval)
                ]
        }
    }

    init() {
        configureEngine()
        configureRemoteCommands()
        startTimeline()
    }

    func prepare(
        requestID: UUID,
        title: String,
        estimatedDuration: TimeInterval
    ) {
        stop()
        self.requestID = requestID
        currentTitle = title
        self.estimatedDuration = estimatedDuration
        state = .preparing
        updateNowPlaying()
    }

    func enqueue(_ chunk: AudioChunk) throws {
        guard chunk.requestID == requestID else { return }
        sampleRate = chunk.sampleRate
        accumulatedSamples.append(contentsOf: chunk.samples)
        generatedDuration = Double(accumulatedSamples.count) / sampleRate
        amplitudes = amplitudeBuckets(from: accumulatedSamples, count: 96)
        let buffer = try makeBuffer(
            samples: chunk.samples,
            sampleRate: chunk.sampleRate
        )
        ensureEngineRunning()
        player.scheduleBuffer(buffer)
        if state == .preparing || state == .buffering {
            state = .buffering
        }
        updateNowPlaying()
    }

    func play() {
        guard !accumulatedSamples.isEmpty else { return }
        ensureEngineRunning()
        if !player.isPlaying {
            player.play()
        }
        state = .playing
        updateNowPlaying()
    }

    func pause() {
        guard player.isPlaying else { return }
        elapsed = currentPlaybackTime()
        seekOffset = elapsed
        player.pause()
        state = .paused
        updateNowPlaying()
    }

    func stop() {
        player.stop()
        accumulatedSamples.removeAll(keepingCapacity: false)
        amplitudes.removeAll(keepingCapacity: false)
        requestID = nil
        currentTitle = ""
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        seekOffset = 0
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func finishBuffering() {
        if state == .buffering {
            play()
        }
        estimatedDuration = generatedDuration
        updateNowPlaying()
    }

    func markFinishedIfNeeded() {
        guard state == .playing,
              generatedDuration > 0,
              elapsed >= generatedDuration - 0.05 else {
            return
        }
        player.pause()
        elapsed = generatedDuration
        state = .finished
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), generatedDuration)
        let wasPlaying = state == .playing
        player.stop()
        seekOffset = target
        elapsed = target
        let startFrame = min(
            Int(target * sampleRate),
            accumulatedSamples.count
        )
        let remaining = Array(accumulatedSamples.dropFirst(startFrame))
        if !remaining.isEmpty, let buffer = try? makeBuffer(
            samples: remaining,
            sampleRate: sampleRate
        ) {
            ensureEngineRunning()
            player.scheduleBuffer(buffer)
            if wasPlaying {
                player.play()
                state = .playing
            } else {
                state = .paused
            }
        }
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentPlaybackTime() + seconds)
    }

    func archive(using archive: AudioArchive) async throws -> AudioArchiveResult {
        guard let requestID, !accumulatedSamples.isEmpty else {
            throw SynthesisError.generatedNoAudio
        }
        return try await archive.writeM4A(
            samples: accumulatedSamples,
            sampleRate: sampleRate,
            requestID: requestID
        )
    }

    func playFile(at url: URL, title: String) throws {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let samples = Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            )
        )
        stop()
        requestID = UUID()
        currentTitle = title
        sampleRate = file.processingFormat.sampleRate
        accumulatedSamples = samples
        generatedDuration = Double(samples.count) / sampleRate
        estimatedDuration = generatedDuration
        amplitudes = amplitudeBuckets(from: samples, count: 96)
        ensureEngineRunning()
        player.scheduleBuffer(buffer)
        player.play()
        state = .playing
        updateNowPlaying()
    }

    func exportWAV(to destination: URL, using archive: AudioArchive) async throws {
        guard !accumulatedSamples.isEmpty else {
            throw SynthesisError.generatedNoAudio
        }
        try await archive.writeWAV(
            samples: accumulatedSamples,
            sampleRate: sampleRate,
            destination: destination
        )
    }

    private func configureEngine() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.rate = Float(rate)
        ensureEngineRunning()
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            state = .failed
        }
    }

    private func makeBuffer(
        samples: [Float],
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.coderInvalidValue)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress else { return }
            channel.update(from: address, count: samples.count)
        }
        return buffer
    }

    private func currentPlaybackTime() -> TimeInterval {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return elapsed
        }
        return min(
            seekOffset + Double(playerTime.sampleTime) / playerTime.sampleRate,
            generatedDuration
        )
    }

    private func startTimeline() {
        timelineTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if self.state == .playing {
                    self.elapsed = self.currentPlaybackTime()
                    self.markFinishedIfNeeded()
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func amplitudeBuckets(from samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let stride = max(samples.count / count, 1)
        return Swift.stride(from: 0, to: samples.count, by: stride)
            .prefix(count)
            .map { start in
                let end = min(start + stride, samples.count)
                let window = samples[start..<end]
                let sum = window.reduce(Double(0)) {
                    $0 + Double($1 * $1)
                }
                return Float(sqrt(sum / Double(max(window.count, 1))))
            }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: backwardSkipInterval)
        ]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: -self.backwardSkipInterval)
            }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [
            NSNumber(value: forwardSkipInterval)
        ]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: self.forwardSkipInterval)
            }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: position.positionTime) }
            return .success
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = [
            0.75, 1, 1.25, 1.5, 1.75, 2
        ]
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent,
                  [0.75, 1, 1.25, 1.5, 1.75, 2].contains(
                    Double(rateEvent.playbackRate)
                  ) else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.rate = Double(rateEvent.playbackRate)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard state != .idle else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: showTitleInNowPlaying && !currentTitle.isEmpty
                ? currentTitle
                : "Say It",
            MPMediaItemPropertyPlaybackDuration: generatedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? rate : 0
        ]
    }
}
