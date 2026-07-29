@preconcurrency import AVFoundation

import Foundation
@preconcurrency import MediaPlayer
import Observation
import SayItCore

@MainActor
@Observable
final class PlaybackController: BackendPlaybackControlling {
    private static let baseStartBufferDuration: TimeInterval = 1.2
    static let highQualityTimePitchOverlap: Float = 32

    static func preferredStartBufferDuration(
        for rate: Double
    ) -> TimeInterval {
        baseStartBufferDuration * max(rate, 1)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var timelineTask: Task<Void, Never>?
    private var audioConfigurationTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var sampleRate: Double = 24_000
    private var scheduleOffset: TimeInterval = 0
    private var requestID: UUID?
    private var configuredSampleRate: Double?
    private var scheduleGeneration = 0
    private var scheduledBufferCount = 0
    private var synthesisIsComplete = false
    private var isReconfiguringAudioGraph = false
    private var amplitudeWindows: [Float] = []
    private var amplitudePendingEnergy = Double.zero
    private var amplitudePendingSampleCount = 0
    private var amplitudeWindowFrameCount = 1_200
    private var lastNowPlayingTimelineUpdate = Date.distantPast

    @ObservationIgnored
    var onFailure: (@MainActor (String) -> Void)?

    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var failureMessage: String?
    var preferredStartBufferDuration: TimeInterval {
        Self.preferredStartBufferDuration(for: rate)
    }
    var shouldStartWhenBuffered: Bool {
        guard state == .preparing || state == .buffering else {
            return false
        }
        return synthesisIsComplete
            || bufferedDuration >= preferredStartBufferDuration
    }
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
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        timePitch.overlap = Self.highQualityTimePitchOverlap
        configureRemoteCommands()
        startTimeline()
        monitorAudioConfiguration()
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
        if !accumulatedSamples.isEmpty,
           !sampleRatesMatch(sampleRate, chunk.sampleRate) {
            throw PlaybackError.inconsistentSampleRate
        }
        let buffer = try makeBuffer(
            samples: chunk.samples,
            sampleRate: chunk.sampleRate
        )
        try prepareAudioGraph(for: buffer.format)
        try validatePlayerFormat(for: buffer)
        schedule(buffer)

        if accumulatedSamples.isEmpty {
            sampleRate = chunk.sampleRate
            resetAmplitudeAnalysis(sampleRate: chunk.sampleRate)
        }

        accumulatedSamples.append(contentsOf: chunk.samples)
        generatedDuration = Double(accumulatedSamples.count) / sampleRate
        appendAmplitudeSamples(chunk.samples)
        if state == .preparing || state == .buffering {
            state = .buffering
        }
        updateNowPlaying()
    }

    func play() {
        do {
            try startPlayback()
        } catch {
            reportFailure(error)
        }
    }

    func pause() {
        guard state == .playing else { return }
        elapsed = currentPlaybackTime()
        player.pause()
        state = .paused
        updateNowPlaying()
    }

    func stop() {
        invalidateScheduledAudio()
        engine.pause()
        accumulatedSamples.removeAll(keepingCapacity: false)
        resetAmplitudeAnalysis(sampleRate: sampleRate)
        requestID = nil
        currentTitle = ""
        failureMessage = nil
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        scheduleOffset = 0
        synthesisIsComplete = false
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func finishBuffering() {
        synthesisIsComplete = true
        estimatedDuration = generatedDuration
        if state == .buffering {
            play()
        } else {
            finishPlaybackIfReady()
        }
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        guard !accumulatedSamples.isEmpty else { return }
        let target = min(max(seconds, 0), generatedDuration)
        let wasPlaying = state == .playing

        do {
            try rescheduleAudio(from: target)
            elapsed = target
            if wasPlaying {
                try startPlayback()
            } else if target >= generatedDuration, synthesisIsComplete {
                completePlayback()
            } else {
                state = .paused
                updateNowPlaying()
            }
        } catch {
            reportFailure(error, shouldResume: wasPlaying)
        }
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
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw PlaybackError.unsupportedAudioFile
        }
        try file.read(into: buffer)
        let samples = try monoSamples(from: buffer)
        let monoBuffer = try makeBuffer(
            samples: samples,
            sampleRate: file.processingFormat.sampleRate
        )

        stop()
        requestID = UUID()
        currentTitle = title
        sampleRate = file.processingFormat.sampleRate
        accumulatedSamples = samples
        generatedDuration = Double(samples.count) / sampleRate
        estimatedDuration = generatedDuration
        synthesisIsComplete = true
        resetAmplitudeAnalysis(sampleRate: sampleRate)
        appendAmplitudeSamples(samples)

        try prepareAudioGraph(for: monoBuffer.format)
        try validatePlayerFormat(for: monoBuffer)
        schedule(monoBuffer)
        try startPlayback()
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

    private func startPlayback() throws {
        guard !accumulatedSamples.isEmpty else { return }

        if state == .finished {
            try rescheduleAudio(from: 0)
            elapsed = 0
        } else if state == .failed || scheduledBufferCount == 0 {
            try rescheduleAudio(from: min(elapsed, generatedDuration))
        }

        try ensureEngineRunning()
        guard scheduledBufferCount > 0 else {
            finishPlaybackIfReady()
            return
        }
        if !player.isPlaying {
            player.play()
        }
        failureMessage = nil
        state = .playing
        updateNowPlaying()
    }

    private func prepareAudioGraph(for format: AVAudioFormat) throws {
        if let configuredSampleRate {
            guard sampleRatesMatch(configuredSampleRate, format.sampleRate),
                  format.channelCount == 1 else {
                throw PlaybackError.inconsistentSampleRate
            }
            try ensureEngineRunning()
            return
        }
        try configureAudioGraph(for: format)
    }

    private func configureAudioGraph(for format: AVAudioFormat) throws {
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw PlaybackError.noOutputDevice
        }

        isReconfiguringAudioGraph = true
        defer { isReconfiguringAudioGraph = false }
        engine.stop()
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(
            timePitch,
            to: engine.mainMixerNode,
            format: format
        )
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        timePitch.overlap = Self.highQualityTimePitchOverlap
        engine.prepare()
        configuredSampleRate = format.sampleRate
        try ensureEngineRunning()
    }

    private func ensureEngineRunning() throws {
        guard !engine.isRunning else { return }
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw PlaybackError.noOutputDevice
        }
        do {
            try engine.start()
        } catch {
            throw PlaybackError.couldNotStartEngine
        }
    }

    private func validatePlayerFormat(for buffer: AVAudioPCMBuffer) throws {
        let outputFormat = player.outputFormat(forBus: 0)
        guard outputFormat.channelCount == buffer.format.channelCount,
              sampleRatesMatch(
                outputFormat.sampleRate,
                buffer.format.sampleRate
              ) else {
            throw PlaybackError.audioFormatMismatch
        }
    }

    private func makeBuffer(
        samples: [Float],
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty else {
            throw PlaybackError.emptyAudio
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
        guard samples.count <= Int(UInt32.max) else {
            throw PlaybackError.audioTooLarge
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw PlaybackError.invalidSamples
        }
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
            throw PlaybackError.audioFormatMismatch
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress else { return }
            channel.update(from: address, count: samples.count)
        }
        return buffer
    }

    private func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0,
              buffer.frameLength > 0 else {
            throw PlaybackError.unsupportedAudioFile
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if channelCount == 1 {
            return Array(
                UnsafeBufferPointer(
                    start: channels[0],
                    count: frameCount
                )
            )
        }

        var samples = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                samples[frameIndex] += channel[frameIndex] / Float(channelCount)
            }
        }
        return samples
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let generation = scheduleGeneration
        scheduledBufferCount += 1
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduledBufferFinished(generation: generation)
            }
        }
    }

    private func scheduledBufferFinished(generation: Int) {
        guard generation == scheduleGeneration else { return }
        scheduledBufferCount = max(scheduledBufferCount - 1, 0)
        finishPlaybackIfReady()
    }

    private func invalidateScheduledAudio() {
        scheduleGeneration &+= 1
        scheduledBufferCount = 0
        player.stop()
    }

    private func rescheduleAudio(from seconds: TimeInterval) throws {
        let target = min(max(seconds, 0), generatedDuration)
        invalidateScheduledAudio()
        scheduleOffset = target
        let startFrame = min(
            Int(target * sampleRate),
            accumulatedSamples.count
        )
        guard startFrame < accumulatedSamples.count else { return }
        let buffer = try makeBuffer(
            samples: Array(accumulatedSamples[startFrame...]),
            sampleRate: sampleRate
        )

        if configuredSampleRate == nil {
            try prepareAudioGraph(for: buffer.format)
        } else {
            try ensureEngineRunning()
        }
        try validatePlayerFormat(for: buffer)
        schedule(buffer)
    }

    private func currentPlaybackTime() -> TimeInterval {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return elapsed
        }
        return min(
            scheduleOffset
                + Double(playerTime.sampleTime) / playerTime.sampleRate,
            generatedDuration
        )
    }

    private func completePlayback() {
        guard state != .finished else { return }
        invalidateScheduledAudio()
        elapsed = generatedDuration
        state = .finished
        updateNowPlaying()
    }

    private func finishPlaybackIfReady() {
        guard !accumulatedSamples.isEmpty,
              scheduledBufferCount == 0 else {
            return
        }
        if synthesisIsComplete {
            completePlayback()
        } else if state == .playing {
            enterBufferingState()
        }
    }

    private var bufferedDuration: TimeInterval {
        let playbackPosition = state == .playing
            ? currentPlaybackTime()
            : elapsed
        return max(generatedDuration - playbackPosition, 0)
    }

    private func enterBufferingState() {
        elapsed = generatedDuration
        invalidateScheduledAudio()
        scheduleOffset = elapsed
        state = .buffering
        updateNowPlaying()
    }

    private func startTimeline() {
        timelineTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if self.state == .playing {
                    self.elapsed = self.currentPlaybackTime()
                    if self.synthesisIsComplete,
                       self.elapsed >= self.generatedDuration - 0.05 {
                        self.completePlayback()
                    } else {
                        self.updateNowPlaying(throttleTimeline: true)
                    }
                }
            }
        }
    }

    private func monitorAudioConfiguration() {
        audioConfigurationTask = Task { @MainActor [weak self] in
            guard let engine = self?.engine else { return }
            for await _ in NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange,
                object: engine
            ) {
                guard !Task.isCancelled, let self else { return }
                self.audioConfigurationDidChange()
            }
        }
    }

    private func audioConfigurationDidChange() {
        guard !isReconfiguringAudioGraph,
              configuredSampleRate != nil,
              !accumulatedSamples.isEmpty else {
            return
        }
        let previousState = state
        let shouldResume = previousState == .playing
        let resumeTime = currentPlaybackTime()

        do {
            invalidateScheduledAudio()
            configuredSampleRate = nil
            let format = try monoFormat(sampleRate: sampleRate)
            try configureAudioGraph(for: format)
            try rescheduleAudio(from: resumeTime)
            elapsed = resumeTime
            if shouldResume {
                try startPlayback()
            } else {
                state = previousState == .failed ? .paused : previousState
                updateNowPlaying()
            }
        } catch {
            reportFailure(error, shouldResume: shouldResume)
        }
    }

    private func monoFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PlaybackError.audioFormatMismatch
        }
        return format
    }

    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private func reportFailure(_ error: Error, shouldResume: Bool = false) {
        if shouldResume {
            elapsed = currentPlaybackTime()
        }
        player.pause()
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Audio playback failed."
        failureMessage = message
        state = .failed
        updateNowPlaying()
        onFailure?(message)
    }

    private func resetAmplitudeAnalysis(sampleRate: Double) {
        amplitudeWindows.removeAll(keepingCapacity: false)
        amplitudePendingEnergy = 0
        amplitudePendingSampleCount = 0
        amplitudeWindowFrameCount = max(Int(sampleRate / 20), 1)
        amplitudes.removeAll(keepingCapacity: false)
    }

    private func appendAmplitudeSamples(_ samples: [Float]) {
        for sample in samples {
            amplitudePendingEnergy += Double(sample * sample)
            amplitudePendingSampleCount += 1
            if amplitudePendingSampleCount >= amplitudeWindowFrameCount {
                amplitudeWindows.append(
                    Float(
                        sqrt(
                            amplitudePendingEnergy
                                / Double(amplitudePendingSampleCount)
                        )
                    )
                )
                amplitudePendingEnergy = 0
                amplitudePendingSampleCount = 0
                compactAmplitudeWindowsIfNeeded()
            }
        }
        amplitudes = displayAmplitudeBuckets(count: 96)
    }

    private func compactAmplitudeWindowsIfNeeded() {
        guard amplitudeWindows.count > 4_096 else { return }
        var compacted: [Float] = []
        compacted.reserveCapacity((amplitudeWindows.count + 1) / 2)
        var index = 0
        while index < amplitudeWindows.count {
            let first = amplitudeWindows[index]
            if index + 1 < amplitudeWindows.count {
                let second = amplitudeWindows[index + 1]
                compacted.append(
                    sqrt((first * first + second * second) / 2)
                )
            } else {
                compacted.append(first)
            }
            index += 2
        }
        amplitudeWindows = compacted
        amplitudeWindowFrameCount *= 2
        amplitudePendingEnergy = 0
        amplitudePendingSampleCount = 0
    }

    private func displayAmplitudeBuckets(count: Int) -> [Float] {
        guard !amplitudeWindows.isEmpty, count > 0 else { return [] }
        let windowSize = max(
            Int(ceil(Double(amplitudeWindows.count) / Double(count))),
            1
        )
        return Swift.stride(
            from: 0,
            to: amplitudeWindows.count,
            by: windowSize
        )
        .prefix(count)
        .map { start in
            let end = min(start + windowSize, amplitudeWindows.count)
            let window = amplitudeWindows[start..<end]
            let energy = window.reduce(Double.zero) {
                $0 + Double($1 * $1)
            }
            return Float(sqrt(energy / Double(window.count)))
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

    private func updateNowPlaying(throttleTimeline: Bool = false) {
        guard state != .idle else { return }
        if throttleTimeline,
           Date.now.timeIntervalSince(lastNowPlayingTimelineUpdate) < 0.5 {
            return
        }
        lastNowPlayingTimelineUpdate = .now
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
