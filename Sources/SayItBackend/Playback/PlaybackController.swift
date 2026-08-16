@preconcurrency import AVFoundation

import Foundation
@preconcurrency import MediaPlayer
import Observation
import SayItCore
import SayItProtocol

@MainActor
@Observable
final class PlaybackController: BackendPlaybackControlling {
    static let modelSwitchFadeDuration: Duration = .milliseconds(24)
    static let highQualityTimePitchOverlap: Float = 32
    static let schedulingHorizon: TimeInterval = 12
    static let schedulingChunkDuration: TimeInterval = 2
    static let fileReadFrameCount = 65_536

    static func preferredStartBufferDuration(
        for rate: Double
    ) -> TimeInterval {
        PlaybackBufferPolicy.progressiveBaseLead * max(rate, 1)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let timeline = TimelineDriver()
    private var audioConfigurationTask: Task<Void, Never>?
    private var audioConfigurationRecoveryTask: Task<Void, Never>?
    private var completionWatchdogTask: Task<Void, Never>?
    private var pcmStore: PCMStore?
    private var frameScheduler: PCMFrameScheduler?
    private var sampleRate: Double = 24_000
    private var scheduleOffset: TimeInterval = 0
    private var requestID: UUID?
    private var configuredSampleRate: Double?
    private var scheduleGeneration = 0
    private var scheduledBufferCount = 0
    private var shouldFadeInNextScheduledBuffer = false
    private var synthesisIsComplete = false
    private var isReconfiguringAudioGraph = false
    private var amplitudeWindows: [Float] = []
    private var amplitudePendingEnergy = Double.zero
    private var amplitudePendingSampleCount = 0
    private var amplitudeWindowFrameCount = 1_200
    private var lastNowPlayingTimelineUpdate = Date.distantPast
    private var stopTransitionGeneration = 0
    private var audioConfigurationRecoveryGeneration = 0
    private var lastStablePlaybackTime: TimeInterval = 0
    private var playbackMode = PlaybackMode.progressive
    private var performanceByModelID: [
        String: SynthesisPerformanceEstimator
    ] = [:]

    @ObservationIgnored
    var onFailure: (@MainActor (String) -> Void)?

    @ObservationIgnored
    var onExternalControl: (@MainActor () -> Void)?

    @ObservationIgnored
    var onStateChange: (@MainActor (PlaybackState) -> Void)?

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var currentModelID: String?
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    private(set) var failureMessage: String?
    var preferredStartBufferDuration: TimeInterval {
        bufferPolicy.preferredSourceLead
    }
    var shouldStartWhenBuffered: Bool {
        guard state == .preparing || state == .buffering else {
            return false
        }
        return bufferPolicy.shouldStart(
            synthesisIsComplete: synthesisIsComplete,
            bufferedDuration: bufferedDuration,
            estimatedRemainingDuration: max(
                estimatedDuration - generatedDuration,
                0
            )
        )
    }
    var showTitleInNowPlaying = false {
        didSet { updateNowPlaying() }
    }
    var rate: Double = 1 {
        didSet {
            timePitch.rate = Float(rate)
            scheduleCompletionWatchdog()
            updateNowPlaying()
        }
    }
    var volume: Double = 1 {
        didSet {
            player.volume = Float(volume)
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
        monitorAudioConfiguration()
    }

    func prepare(
        requestID: UUID,
        title: String,
        estimatedDuration: TimeInterval,
        modelID: String?
    ) {
        stop()
        self.requestID = requestID
        currentTitle = title
        currentModelID = modelID
        self.estimatedDuration = estimatedDuration
        state = .preparing
        updateNowPlaying()
    }

    func enqueue(_ chunk: AudioChunk) throws {
        guard chunk.requestID == requestID else { return }
        guard !chunk.samples.isEmpty else {
            throw PlaybackError.emptyAudio
        }
        if let pcmStore,
           !sampleRatesMatch(pcmStore.sampleRate, chunk.sampleRate) {
            throw PlaybackError.inconsistentSampleRate
        }
        if pcmStore == nil {
            sampleRate = chunk.sampleRate
            pcmStore = try PCMStore(sampleRate: chunk.sampleRate)
            frameScheduler = makeFrameScheduler(sampleRate: chunk.sampleRate)
            resetAmplitudeAnalysis(sampleRate: chunk.sampleRate)
        }

        guard let pcmStore else {
            throw PlaybackError.emptyAudio
        }
        try pcmStore.append(chunk.samples)
        generatedDuration = Double(pcmStore.frameCount) / sampleRate
        appendAmplitudeSamples(chunk.samples)
        try prepareAudioGraph(for: monoFormat(sampleRate: sampleRate))
        try scheduleAvailableAudio()
        if state == .preparing || state == .buffering {
            state = .buffering
        }
        updateNowPlaying()
    }

    func setSpokenText(_ text: String) {
        spokenText = text
        spokenChunks = []
    }

    func appendSpokenChunk(_ chunk: PlaybackTextChunk) {
        spokenChunks.append(chunk)
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
    }

    func observeSynthesisMetrics(_ metrics: SynthesisMetrics) {
        guard let currentModelID else { return }
        var estimator = performanceByModelID[currentModelID]
            ?? SynthesisPerformanceEstimator()
        estimator.record(metrics)
        performanceByModelID[currentModelID] = estimator
    }

    func play() {
        cancelAudioConfigurationRecovery()
        do {
            try startPlayback()
        } catch {
            reportFailure(error)
        }
    }

    func pause() {
        guard state == .playing else { return }
        elapsed = AudioRouteRecoveryPolicy.stableAnchor(
            lastRendered: lastStablePlaybackTime,
            fallback: currentPlaybackTime(),
            duration: generatedDuration
        )
        lastStablePlaybackTime = elapsed
        cancelAudioConfigurationRecovery()
        player.pause()
        stopTimeline()
        state = .paused
        updateNowPlaying()
    }

    func stop() {
        stopTransitionGeneration &+= 1
        finishStopping()
    }

    func stopSmoothly() async {
        await performSmoothStop(duration: .milliseconds(12))
    }

    func stopForModelSwitch() async {
        await performSmoothStop(duration: Self.modelSwitchFadeDuration)
    }

    private func performSmoothStop(duration: Duration) async {
        cancelAudioConfigurationRecovery()
        stopTransitionGeneration &+= 1
        let generation = stopTransitionGeneration
        requestID = nil

        guard player.isPlaying, hasStoredAudio else {
            finishStopping()
            return
        }

        do {
            let actualDuration = try scheduleFadeOut(
                from: currentPlaybackTime(),
                requestedDuration: duration
            )
            stopTimeline()
            state = .paused
            try await Task.sleep(for: actualDuration)
        } catch {
            guard generation == stopTransitionGeneration else { return }
            finishStopping()
            return
        }
        guard generation == stopTransitionGeneration else { return }
        finishStopping()
    }

    private func scheduleFadeOut(
        from seconds: TimeInterval,
        requestedDuration: Duration
    ) throws -> Duration {
        let target = min(max(seconds, 0), generatedDuration)
        guard let pcmStore else {
            return .zero
        }
        let startFrame = min(
            Int64(target * sampleRate),
            pcmStore.frameCount
        )
        guard startFrame < pcmStore.frameCount else {
            return .zero
        }
        let requestedSeconds = Self.timeInterval(for: requestedDuration)
        let requestedFrames = max(Int(requestedSeconds * sampleRate), 1)
        let samples = try pcmStore.readFrames(
            startingAt: startFrame,
            count: requestedFrames
        )
        let buffer = try makeBuffer(
            samples: PCMTransitionRamp.fadeOut(samples),
            sampleRate: sampleRate
        )

        invalidateScheduledAudio()
        scheduleOffset = target
        if configuredSampleRate == nil {
            try prepareAudioGraph(for: buffer.format)
        } else {
            try ensureEngineRunning()
        }
        try validatePlayerFormat(for: buffer)
        player.scheduleBuffer(buffer)
        player.volume = Float(volume)
        player.play()
        return .seconds(Double(samples.count) / sampleRate)
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1e18
    }

    private func finishStopping() {
        cancelAudioConfigurationRecovery()
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        invalidateScheduledAudio()
        engine.pause()
        player.volume = Float(volume)
        pcmStore = nil
        frameScheduler = nil
        resetAmplitudeAnalysis(sampleRate: sampleRate)
        requestID = nil
        currentTitle = ""
        currentModelID = nil
        spokenText = ""
        spokenChunks = []
        failureMessage = nil
        elapsed = 0
        lastStablePlaybackTime = 0
        generatedDuration = 0
        estimatedDuration = 0
        scheduleOffset = 0
        synthesisIsComplete = false
        configuredSampleRate = nil
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
            scheduleCompletionWatchdog()
        }
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        guard hasStoredAudio else { return }
        cancelAudioConfigurationRecovery()
        let target = min(max(seconds, 0), generatedDuration)
        let wasPlaying = state == .playing

        do {
            try rescheduleAudio(from: target)
            elapsed = target
            lastStablePlaybackTime = target
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
        let current = AudioRouteRecoveryPolicy.stableAnchor(
            lastRendered: lastStablePlaybackTime,
            fallback: currentPlaybackTime(),
            duration: generatedDuration
        )
        seek(to: current + seconds)
    }

    func archive(using archive: AudioArchive) async throws -> AudioArchiveResult {
        guard let requestID, let pcmStore, pcmStore.frameCount > 0 else {
            throw SynthesisError.generatedNoAudio
        }
        let snapshot = try pcmStore.snapshot()
        return try await archive.writeM4A(
            source: snapshot,
            requestID: requestID
        )
    }

    func playFile(at url: URL, title: String, modelID: String?) throws {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0 else {
            throw PlaybackError.unsupportedAudioFile
        }

        stop()
        requestID = UUID()
        currentTitle = title
        currentModelID = modelID
        sampleRate = file.processingFormat.sampleRate
        pcmStore = try PCMStore(sampleRate: sampleRate)
        frameScheduler = makeFrameScheduler(sampleRate: sampleRate)
        resetAmplitudeAnalysis(sampleRate: sampleRate)

        do {
            try importAudioFile(file)
            guard hasStoredAudio else {
                throw PlaybackError.unsupportedAudioFile
            }
            generatedDuration = Double(pcmStore?.frameCount ?? 0) / sampleRate
            estimatedDuration = generatedDuration
            synthesisIsComplete = true
            try prepareAudioGraph(for: monoFormat(sampleRate: sampleRate))
            try scheduleAvailableAudio()
            try startPlayback()
        } catch {
            stop()
            throw error
        }
    }

    func exportWAV(to destination: URL, using archive: AudioArchive) async throws {
        guard let pcmStore, pcmStore.frameCount > 0 else {
            throw SynthesisError.generatedNoAudio
        }
        try await archive.writeWAV(
            source: pcmStore.snapshot(),
            destination: destination
        )
    }

    private func startPlayback() throws {
        guard hasStoredAudio else { return }

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
        lastStablePlaybackTime = elapsed
        startTimeline()
        scheduleCompletionWatchdog()
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

    private func schedule(
        _ buffer: AVAudioPCMBuffer,
        sourceFrameCount: Int64
    ) {
        let generation = scheduleGeneration
        scheduledBufferCount += 1
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduledBufferFinished(
                    generation: generation,
                    frameCount: sourceFrameCount
                )
            }
        }
    }

    private func scheduledBufferFinished(
        generation: Int,
        frameCount: Int64
    ) {
        guard generation == scheduleGeneration else { return }
        scheduledBufferCount = max(scheduledBufferCount - 1, 0)
        frameScheduler?.didComplete(frameCount: frameCount)
        do {
            try scheduleAvailableAudio()
        } catch {
            reportFailure(error)
            return
        }
        finishPlaybackIfReady()
    }

    private func invalidateScheduledAudio() {
        stopTimeline()
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        scheduleGeneration &+= 1
        scheduledBufferCount = 0
        if var frameScheduler {
            frameScheduler.reset(startingAt: frameScheduler.nextFrame)
            self.frameScheduler = frameScheduler
        }
        player.stop()
    }

    private func rescheduleAudio(from seconds: TimeInterval) throws {
        let target = min(max(seconds, 0), generatedDuration)
        invalidateScheduledAudio()
        let availableFrameCount = pcmStore?.frameCount ?? 0
        let startFrame = min(
            Int64((target * sampleRate).rounded(.down)),
            availableFrameCount
        )
        scheduleOffset = Double(startFrame) / sampleRate
        frameScheduler?.reset(startingAt: startFrame)
        shouldFadeInNextScheduledBuffer = startFrame < availableFrameCount
        try scheduleAvailableAudio()
    }

    private func scheduleAvailableAudio() throws {
        guard let pcmStore, var frameScheduler else { return }
        while let range = frameScheduler.nextRange(
            availableFrameCount: pcmStore.frameCount
        ) {
            var samples = try pcmStore.readFrames(
                startingAt: range.lowerBound,
                count: Int(range.count)
            )
            guard samples.count == range.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if shouldFadeInNextScheduledBuffer {
                samples = PCMTransitionRamp.fadeInHead(
                    samples,
                    frameCount: transitionFrameCount
                )
                shouldFadeInNextScheduledBuffer = false
            }
            let buffer = try makeBuffer(
                samples: samples,
                sampleRate: sampleRate
            )
            if configuredSampleRate == nil {
                try prepareAudioGraph(for: buffer.format)
            } else {
                try ensureEngineRunning()
            }
            try validatePlayerFormat(for: buffer)
            schedule(buffer, sourceFrameCount: Int64(range.count))
            frameScheduler.didSchedule(range)
        }
        self.frameScheduler = frameScheduler
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
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        invalidateScheduledAudio()
        elapsed = generatedDuration
        lastStablePlaybackTime = elapsed
        state = .finished
        updateNowPlaying()
    }

    private func finishPlaybackIfReady() {
        guard hasStoredAudio,
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

    private var bufferPolicy: PlaybackBufferPolicy {
        PlaybackBufferPolicy(
            mode: playbackMode,
            rate: rate,
            estimator: currentModelID.flatMap {
                performanceByModelID[$0]
            } ?? SynthesisPerformanceEstimator()
        )
    }

    private var transitionFrameCount: Int {
        max(
            Int((sampleRate * PCMStreamConditioner.boundaryDuration).rounded()),
            1
        )
    }

    private func scheduleCompletionWatchdog() {
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        guard synthesisIsComplete,
              state == .playing,
              generatedDuration > 0 else {
            return
        }
        let remaining = max(
            generatedDuration - currentPlaybackTime(),
            0
        )
        let delay = remaining / max(rate, 0.1) + 0.75
        let generation = scheduleGeneration
        completionWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  generation == self.scheduleGeneration,
                  self.state == .playing else {
                return
            }
            self.elapsed = self.currentPlaybackTime()
            let frameTolerance = 1 / max(self.sampleRate, 1)
            if self.elapsed >= self.generatedDuration - frameTolerance {
                self.completePlayback()
            } else {
                self.scheduleCompletionWatchdog()
            }
        }
    }

    private func enterBufferingState() {
        elapsed = generatedDuration
        lastStablePlaybackTime = elapsed
        invalidateScheduledAudio()
        scheduleOffset = elapsed
        state = .buffering
        updateNowPlaying()
    }

    private func startTimeline() {
        timeline.start { [weak self] in
            guard let self, self.state == .playing else { return }
            self.elapsed = self.currentPlaybackTime()
            self.lastStablePlaybackTime = self.elapsed
            self.updateNowPlaying(throttleTimeline: true)
        }
    }

    private func stopTimeline() {
        timeline.stop()
    }

    private func monitorAudioConfiguration() {
        audioConfigurationTask = Task { @MainActor [weak self] in
            guard let engine = self?.engine else { return }
            for await _ in NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange,
                object: engine
            ) {
                guard !Task.isCancelled, let self else { return }
                self.scheduleAudioConfigurationRecovery()
            }
        }
    }

    private func scheduleAudioConfigurationRecovery() {
        guard !isReconfiguringAudioGraph,
              configuredSampleRate != nil,
              hasStoredAudio,
              state != .idle,
              state != .finished else {
            return
        }
        let previousState = state
        let resumeTime = AudioRouteRecoveryPolicy.stableAnchor(
            lastRendered: lastStablePlaybackTime,
            fallback: elapsed,
            duration: generatedDuration
        )
        audioConfigurationRecoveryGeneration &+= 1
        let generation = audioConfigurationRecoveryGeneration
        audioConfigurationRecoveryTask?.cancel()
        audioConfigurationRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: AudioRouteRecoveryPolicy.debounceDelay
                )
                var lastError: Error?
                for delay in AudioRouteRecoveryPolicy.retryDelays {
                    if delay > .zero {
                        try await Task.sleep(for: delay)
                    }
                    guard let self,
                          generation
                            == self.audioConfigurationRecoveryGeneration,
                          self.hasStoredAudio else {
                        return
                    }
                    do {
                        try self.recoverAudioConfiguration(
                            from: resumeTime,
                            previousState: previousState
                        )
                        self.audioConfigurationRecoveryTask = nil
                        return
                    } catch {
                        lastError = error
                        guard AudioRouteRecoveryPolicy.canRetry(error) else {
                            break
                        }
                    }
                }
                guard let self,
                      generation
                        == self.audioConfigurationRecoveryGeneration,
                      let lastError else {
                    return
                }
                self.audioConfigurationRecoveryTask = nil
                self.reportFailure(lastError)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation
                        == self.audioConfigurationRecoveryGeneration else {
                    return
                }
                self.audioConfigurationRecoveryTask = nil
                self.reportFailure(error)
            }
        }
    }

    private func recoverAudioConfiguration(
        from resumeTime: TimeInterval,
        previousState: PlaybackState
    ) throws {
        invalidateScheduledAudio()
        configuredSampleRate = nil
        let format = try monoFormat(sampleRate: sampleRate)
        try configureAudioGraph(for: format)
        try rescheduleAudio(from: resumeTime)
        elapsed = resumeTime
        lastStablePlaybackTime = resumeTime
        if previousState == .playing {
            try startPlayback()
        } else {
            state = previousState == .failed ? .paused : previousState
            updateNowPlaying()
        }
    }

    private func cancelAudioConfigurationRecovery() {
        audioConfigurationRecoveryGeneration &+= 1
        audioConfigurationRecoveryTask?.cancel()
        audioConfigurationRecoveryTask = nil
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

    private var hasStoredAudio: Bool {
        (pcmStore?.frameCount ?? 0) > 0
    }

    private func makeFrameScheduler(
        sampleRate: Double,
        startingAt startFrame: Int64 = 0
    ) -> PCMFrameScheduler {
        PCMFrameScheduler(
            sampleRate: sampleRate,
            horizonDuration: Self.schedulingHorizon,
            chunkDuration: Self.schedulingChunkDuration,
            startingAt: startFrame
        )
    }

    private func importAudioFile(_ file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(Self.fileReadFrameCount)
        ) else {
            throw PlaybackError.unsupportedAudioFile
        }

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(
                min(
                    remaining,
                    AVAudioFramePosition(Self.fileReadFrameCount)
                )
            )
            try file.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            let samples = try monoSamples(from: buffer)
            try pcmStore?.append(samples)
            appendAmplitudeSamples(samples)
        }
    }

    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private func reportFailure(_ error: Error, shouldResume: Bool = false) {
        cancelAudioConfigurationRecovery()
        stopTimeline()
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
            Task { @MainActor in
                guard let self else { return }
                self.play()
                self.onExternalControl?()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause()
                self.onExternalControl?()
            }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .playing {
                    self.pause()
                } else {
                    self.play()
                }
                self.onExternalControl?()
            }
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stop()
                self.onExternalControl?()
            }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: self.forwardSkipInterval)
                self.onExternalControl?()
            }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: -self.backwardSkipInterval)
                self.onExternalControl?()
            }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: backwardSkipInterval)
        ]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: -self.backwardSkipInterval)
                self.onExternalControl?()
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
                self.onExternalControl?()
            }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: position.positionTime)
                self.onExternalControl?()
            }
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
                guard let self else { return }
                self.rate = Double(rateEvent.playbackRate)
                self.onExternalControl?()
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

extension PlaybackController {
    @MainActor
    final class TimelineDriver {
        typealias Sleep = @Sendable (Duration) async throws -> Void

        static let interval = Duration.milliseconds(250)

        private let sleep: Sleep
        private var task: Task<Void, Never>?
        private var generation: UInt64 = 0

        var isActive: Bool {
            task != nil
        }

        init(
            sleep: @escaping Sleep = { duration in
                try await Task.sleep(for: duration)
            }
        ) {
            self.sleep = sleep
        }

        deinit {
            task?.cancel()
        }

        func start(
            onTick: @escaping @MainActor @Sendable () -> Void
        ) {
            guard task == nil else { return }
            generation &+= 1
            let activeGeneration = generation
            let sleep = self.sleep
            task = Task { @MainActor [weak self] in
                do {
                    while !Task.isCancelled {
                        try await sleep(Self.interval)
                        try Task.checkCancellation()
                        guard self?.generation == activeGeneration else {
                            return
                        }
                        onTick()
                    }
                } catch {
                    // Cancellation and clock failures both end this cadence.
                }
                self?.clearIfCurrent(activeGeneration)
            }
        }

        func stop() {
            generation &+= 1
            task?.cancel()
            task = nil
        }

        private func clearIfCurrent(_ completedGeneration: UInt64) {
            guard generation == completedGeneration else { return }
            task = nil
        }
    }
}
