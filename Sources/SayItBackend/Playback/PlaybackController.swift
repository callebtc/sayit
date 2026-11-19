import Foundation
import Observation
import PlaybackDSP
import SayItCore
import SayItProtocol

@MainActor
@Observable
final class PlaybackController: BackendPlaybackControlling {
    static let modelSwitchFadeDuration: Duration = .milliseconds(24)
    static let timeStretchEngineName = TimeStretchStream.engineName
    static let schedulingHorizon: TimeInterval = 12
    static let schedulingChunkDuration: TimeInterval = 2
    static let fileReadFrameCount = 65_536

    private static let timelineInterval: Duration = .milliseconds(250)
    private static let smoothStopFadeDuration: Duration = .milliseconds(12)
    private static let nowPlayingThrottleInterval: Duration = .milliseconds(500)
    private static let routeRecoveryDebounceDelay: Duration = .milliseconds(150)
    private static let routeRecoveryRetryDelays: [Duration] = [
        .zero,
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500)
    ]

    private struct FrameHorizon {
        let horizonFrameCount: Int64
        let chunkFrameCount: Int64
        private(set) var nextFrame: Int64
        private(set) var scheduledFrameCount: Int64 = 0

        init(
            sampleRate: Double,
            horizonDuration: TimeInterval,
            chunkDuration: TimeInterval,
            startingAt startFrame: Int64 = 0
        ) {
            horizonFrameCount = max(
                Int64((sampleRate * horizonDuration).rounded()),
                1
            )
            chunkFrameCount = max(
                Int64((sampleRate * chunkDuration).rounded()),
                1
            )
            nextFrame = max(startFrame, 0)
        }

        func nextRange(availableFrameCount: Int64) -> Range<Int64>? {
            guard nextFrame < availableFrameCount,
                  scheduledFrameCount < horizonFrameCount else {
                return nil
            }
            let available = availableFrameCount - nextFrame
            let horizonRemaining = horizonFrameCount - scheduledFrameCount
            let count = min(chunkFrameCount, available, horizonRemaining)
            guard count > 0 else { return nil }
            return nextFrame..<(nextFrame + count)
        }

        mutating func didSchedule(_ range: Range<Int64>) {
            guard range.lowerBound == nextFrame, !range.isEmpty else { return }
            nextFrame = range.upperBound
            scheduledFrameCount += Int64(range.count)
        }

        mutating func didComplete(frameCount: Int64) {
            scheduledFrameCount = max(scheduledFrameCount - frameCount, 0)
        }

        mutating func reset(startingAt startFrame: Int64) {
            nextFrame = max(startFrame, 0)
            scheduledFrameCount = 0
        }
    }

    private let audioOutput: any PlaybackAudioOutput
    private let mediaSession: any PlaybackMediaSession
    private let clock: any PlaybackClock
    private var timeStretch: TimeStretchStream?
    private var processingIsComplete = false
    private var pendingSourceFrames: Int64 = 0
    private var scheduledOutputFrames: Int64 = 0
    private var renderRate: Double = 1
    @ObservationIgnored
    private var timelineTask: Task<Void, Never>?
    private var timelineGeneration: UInt64 = 0
    @ObservationIgnored
    private var audioConfigurationRecoveryTask: Task<Void, Never>?
    @ObservationIgnored
    private var completionWatchdogTask: Task<Void, Never>?
    private var pcmStore: PCMStore?
    private var frameHorizon: FrameHorizon?
    private var sampleRate: Double = 24_000
    private var scheduleOffset: TimeInterval = 0
    private var requestID: UUID?
    private var configuredSampleRate: Double?
    private var scheduleGeneration = 0
    private var scheduledBufferCount = 0
    private var shouldFadeInNextScheduledBuffer = false
    private var synthesisIsComplete = false
    private var amplitudeWindows: [Float] = []
    private var amplitudePendingEnergy = Double.zero
    private var amplitudePendingSampleCount = 0
    private var amplitudeWindowFrameCount = 1_200
    private var lastNowPlayingTimelineUpdate: ContinuousClock.Instant?
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
            guard rate != oldValue else { return }
            cancelAudioConfigurationRecovery()
            let wasPlaying = state == .playing
            let anchor = currentPlaybackTime()
            do {
                if hasStoredAudio {
                    try rescheduleAudio(from: anchor)
                    elapsed = anchor
                    lastStablePlaybackTime = anchor
                    if wasPlaying { try startPlayback() }
                }
            } catch {
                reportFailure(error, shouldResume: wasPlaying)
            }
            scheduleCompletionWatchdog()
            updateNowPlaying()
        }
    }

    var volume: Double = 1 {
        didSet {
            audioOutput.setVolume(Float(volume))
        }
    }

    var backwardSkipInterval: TimeInterval = 15 {
        didSet {
            mediaSession.setBackwardSkipInterval(backwardSkipInterval)
        }
    }

    var forwardSkipInterval: TimeInterval = 30 {
        didSet {
            mediaSession.setForwardSkipInterval(forwardSkipInterval)
        }
    }

    init(
        audioOutput: any PlaybackAudioOutput = LivePlaybackAudioOutput(),
        mediaSession: any PlaybackMediaSession = LivePlaybackMediaSession(),
        clock: any PlaybackClock = LivePlaybackClock()
    ) {
        self.audioOutput = audioOutput
        self.mediaSession = mediaSession
        self.clock = clock
        audioOutput.onConfigurationChange = { [weak self] in
            self?.scheduleAudioConfigurationRecovery()
        }
        configureRemoteCommands()
    }

    deinit {
        timelineTask?.cancel()
        completionWatchdogTask?.cancel()
        audioConfigurationRecoveryTask?.cancel()
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
            frameHorizon = makeFrameHorizon(sampleRate: chunk.sampleRate)
            resetAmplitudeAnalysis(sampleRate: chunk.sampleRate)
        }

        guard let pcmStore else {
            throw PlaybackError.emptyAudio
        }
        try pcmStore.append(chunk.samples)
        generatedDuration = Double(pcmStore.frameCount) / sampleRate
        appendAmplitudeSamples(chunk.samples)
        try prepareAudioGraph(sampleRate: sampleRate)
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
        if let last = spokenChunks.last, last.textStart == chunk.textStart {
            spokenChunks[spokenChunks.count - 1] = chunk
        } else {
            spokenChunks.append(chunk)
        }
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
        elapsed = Self.stablePlaybackAnchor(
            lastRendered: lastStablePlaybackTime,
            fallback: currentPlaybackTime(),
            duration: generatedDuration
        )
        lastStablePlaybackTime = elapsed
        cancelAudioConfigurationRecovery()
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        audioOutput.pause()
        stopTimeline()
        state = .paused
        updateNowPlaying()
    }

    func stop() {
        stopTransitionGeneration &+= 1
        finishStopping()
    }

    func stopSmoothly() async {
        await performSmoothStop(duration: Self.smoothStopFadeDuration)
    }

    func stopForModelSwitch() async {
        await performSmoothStop(duration: Self.modelSwitchFadeDuration)
    }

    private func performSmoothStop(duration: Duration) async {
        cancelAudioConfigurationRecovery()
        stopTransitionGeneration &+= 1
        let generation = stopTransitionGeneration
        requestID = nil

        guard audioOutput.isPlaying, hasStoredAudio else {
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
            if actualDuration > .zero {
                try await clock.sleep(for: actualDuration)
            }
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
        guard !samples.isEmpty else {
            return .zero
        }
        let fadedSamples = PCMTransitionRamp.fadeOut(samples)

        invalidateScheduledAudio()
        scheduleOffset = target
        try prepareAudioGraph(sampleRate: sampleRate)
        try audioOutput.scheduleBuffer(
            fadedSamples,
            sampleRate: sampleRate,
            completion: nil
        )
        audioOutput.setVolume(Float(volume))
        audioOutput.play()
        return .seconds(Double(fadedSamples.count) / sampleRate)
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
        audioOutput.pauseEngine()
        audioOutput.setVolume(Float(volume))
        pcmStore = nil
        frameHorizon = nil
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
        lastNowPlayingTimelineUpdate = nil
        state = .idle
        mediaSession.clearNowPlaying()
    }

    func finishBuffering() {
        synthesisIsComplete = true
        estimatedDuration = generatedDuration
        do {
            try scheduleAvailableAudio()
        } catch {
            reportFailure(error)
            return
        }
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
        let current = Self.stablePlaybackAnchor(
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
        let file = try audioOutput.openAudioFile(
            at: url,
            chunkFrameCount: Self.fileReadFrameCount
        )

        stop()
        requestID = UUID()
        currentTitle = title
        currentModelID = modelID
        sampleRate = file.sampleRate
        pcmStore = try PCMStore(sampleRate: sampleRate)
        frameHorizon = makeFrameHorizon(sampleRate: sampleRate)
        resetAmplitudeAnalysis(sampleRate: sampleRate)

        do {
            while let samples = try file.readNextChunk() {
                guard !samples.isEmpty else { break }
                try pcmStore?.append(samples)
                appendAmplitudeSamples(samples)
            }
            guard hasStoredAudio else {
                throw PlaybackError.unsupportedAudioFile
            }
            generatedDuration = Double(pcmStore?.frameCount ?? 0) / sampleRate
            estimatedDuration = generatedDuration
            synthesisIsComplete = true
            try prepareAudioGraph(sampleRate: sampleRate)
            try scheduleAvailableAudio()
            try startPlayback()
        } catch {
            stop()
            throw error
        }
    }

    private func startPlayback() throws {
        guard hasStoredAudio else { return }

        if state == .finished {
            try rescheduleAudio(from: 0)
            elapsed = 0
        } else if state == .failed || scheduledBufferCount == 0 {
            try rescheduleAudio(from: min(elapsed, generatedDuration))
        }

        try audioOutput.ensureEngineRunning()
        guard scheduledBufferCount > 0 else {
            finishPlaybackIfReady()
            return
        }
        if !audioOutput.isPlaying {
            audioOutput.play()
        }
        failureMessage = nil
        state = .playing
        lastStablePlaybackTime = elapsed
        startTimeline()
        scheduleCompletionWatchdog()
        updateNowPlaying()
    }

    private func prepareAudioGraph(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
        if let configuredSampleRate {
            guard sampleRatesMatch(configuredSampleRate, sampleRate) else {
                throw PlaybackError.inconsistentSampleRate
            }
            try audioOutput.ensureEngineRunning()
            return
        }
        try audioOutput.configureGraph(sampleRate: sampleRate)
        configuredSampleRate = sampleRate
    }

    private func schedule(
        _ samples: [Float],
        sourceFrameCount: Int64
    ) throws {
        let generation = scheduleGeneration
        scheduledBufferCount += 1
        scheduledOutputFrames += Int64(samples.count)
        do {
            try audioOutput.scheduleBuffer(
                samples,
                sampleRate: sampleRate
            ) { [weak self] in
                self?.scheduledBufferFinished(
                    generation: generation,
                    frameCount: sourceFrameCount
                )
            }
        } catch {
            scheduledBufferCount = max(scheduledBufferCount - 1, 0)
            scheduledOutputFrames = max(
                scheduledOutputFrames - Int64(samples.count),
                0
            )
            throw error
        }
    }

    private func scheduledBufferFinished(
        generation: Int,
        frameCount: Int64
    ) {
        guard generation == scheduleGeneration else { return }
        scheduledBufferCount = max(scheduledBufferCount - 1, 0)
        frameHorizon?.didComplete(frameCount: frameCount)
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
        scheduledOutputFrames = 0
        pendingSourceFrames = 0
        timeStretch = nil
        processingIsComplete = false
        renderRate = rate
        if var frameHorizon {
            frameHorizon.reset(startingAt: frameHorizon.nextFrame)
            self.frameHorizon = frameHorizon
        }
        audioOutput.stopPlayer()
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
        frameHorizon?.reset(startingAt: startFrame)
        shouldFadeInNextScheduledBuffer = startFrame < availableFrameCount
        try scheduleAvailableAudio()
    }

    private func scheduleAvailableAudio() throws {
        guard let pcmStore, var frameHorizon, !processingIsComplete else {
            return
        }
        if timeStretch == nil {
            renderRate = rate
            timeStretch = try TimeStretchStream(
                sampleRate: sampleRate,
                rate: renderRate
            )
        }
        guard let timeStretch else { return }
        while let range = frameHorizon.nextRange(
            availableFrameCount: pcmStore.frameCount
        ) {
            let samples = try pcmStore.readFrames(
                startingAt: range.lowerBound,
                count: Int(range.count)
            )
            guard samples.count == range.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let output = try timeStretch.process(samples)
            pendingSourceFrames += Int64(range.count)
            frameHorizon.didSchedule(range)
            try scheduleProcessedAudio(output)
        }
        if synthesisIsComplete, frameHorizon.nextFrame == pcmStore.frameCount {
            let tail = try timeStretch.process([], final: true)
            try scheduleProcessedAudio(tail)
            // A unity-rate stream has no delayed output to attach this accounting to.
            if pendingSourceFrames > 0 {
                frameHorizon.didComplete(frameCount: pendingSourceFrames)
                pendingSourceFrames = 0
            }
            processingIsComplete = true
        }
        self.frameHorizon = frameHorizon
    }

    private func scheduleProcessedAudio(_ output: [Float]) throws {
        guard !output.isEmpty else { return }
        var samples = output
        if shouldFadeInNextScheduledBuffer {
            samples = PCMTransitionRamp.fadeInHead(
                samples,
                frameCount: transitionFrameCount
            )
            shouldFadeInNextScheduledBuffer = false
        }
        try prepareAudioGraph(sampleRate: sampleRate)
        try schedule(samples, sourceFrameCount: pendingSourceFrames)
        pendingSourceFrames = 0
    }

    private func currentPlaybackTime() -> TimeInterval {
        guard audioOutput.isPlaying,
              let rendered = audioOutput.renderedPosition(),
              rendered.sampleRate > 0 else {
            return elapsed
        }
        let renderedFrames = max(min(rendered.frame, scheduledOutputFrames), 0)
        return min(
            scheduleOffset
                + Double(renderedFrames) / rendered.sampleRate * renderRate,
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
        if synthesisIsComplete, processingIsComplete {
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
        let clock = self.clock
        completionWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: .seconds(delay))
                try Task.checkCancellation()
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
        // Restart from the audible source position, including the processor's
        // held-back lookahead, when progressive synthesis catches up.
        elapsed = currentPlaybackTime()
        lastStablePlaybackTime = elapsed
        invalidateScheduledAudio()
        let frame = Int64((elapsed * sampleRate).rounded(.down))
        frameHorizon?.reset(startingAt: frame)
        scheduleOffset = Double(frame) / sampleRate
        state = .buffering
        updateNowPlaying()
    }

    private func startTimeline() {
        guard timelineTask == nil else { return }
        timelineGeneration &+= 1
        let activeGeneration = timelineGeneration
        let clock = self.clock
        timelineTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    try await clock.sleep(for: Self.timelineInterval)
                    try Task.checkCancellation()
                    guard let self,
                          self.timelineGeneration == activeGeneration else {
                        return
                    }
                    if self.state == .playing {
                        self.elapsed = self.currentPlaybackTime()
                        self.lastStablePlaybackTime = self.elapsed
                        self.updateNowPlaying(throttleTimeline: true)
                    }
                }
            } catch {
                // Cancellation and clock failures both end this cadence.
            }
            self?.clearTimelineIfCurrent(activeGeneration)
        }
    }

    private func stopTimeline() {
        timelineGeneration &+= 1
        timelineTask?.cancel()
        timelineTask = nil
    }

    private func clearTimelineIfCurrent(_ completedGeneration: UInt64) {
        guard timelineGeneration == completedGeneration else { return }
        timelineTask = nil
    }

    private func scheduleAudioConfigurationRecovery() {
        guard configuredSampleRate != nil,
              hasStoredAudio,
              state != .idle,
              state != .finished else {
            return
        }
        let previousState = state
        let resumeTime = Self.stablePlaybackAnchor(
            lastRendered: lastStablePlaybackTime,
            fallback: elapsed,
            duration: generatedDuration
        )
        audioConfigurationRecoveryGeneration &+= 1
        let generation = audioConfigurationRecoveryGeneration
        audioConfigurationRecoveryTask?.cancel()
        let clock = self.clock
        audioConfigurationRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: Self.routeRecoveryDebounceDelay)
                try Task.checkCancellation()
                var lastError: (any Error)?
                for delay in Self.routeRecoveryRetryDelays {
                    if delay > .zero {
                        try await clock.sleep(for: delay)
                        try Task.checkCancellation()
                    }
                    guard let self,
                          generation == self.audioConfigurationRecoveryGeneration,
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
                        guard Self.canRetryAudioConfigurationError(error) else {
                            break
                        }
                    }
                }
                guard let self,
                      generation == self.audioConfigurationRecoveryGeneration,
                      let lastError else {
                    return
                }
                self.audioConfigurationRecoveryTask = nil
                self.reportFailure(lastError)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.audioConfigurationRecoveryGeneration else {
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
        try prepareAudioGraph(sampleRate: sampleRate)
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

    private static func stablePlaybackAnchor(
        lastRendered: TimeInterval,
        fallback: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let rendered = lastRendered.isFinite ? lastRendered : 0
        let fallback = fallback.isFinite ? fallback : 0
        let duration = duration.isFinite ? max(duration, 0) : 0
        return min(max(rendered, fallback, 0), duration)
    }

    private static func canRetryAudioConfigurationError(_ error: any Error) -> Bool {
        switch error {
        case PlaybackError.noOutputDevice,
             PlaybackError.couldNotStartEngine:
            true
        default:
            false
        }
    }

    private var hasStoredAudio: Bool {
        (pcmStore?.frameCount ?? 0) > 0
    }

    private func makeFrameHorizon(
        sampleRate: Double,
        startingAt startFrame: Int64 = 0
    ) -> FrameHorizon {
        FrameHorizon(
            sampleRate: sampleRate,
            horizonDuration: Self.schedulingHorizon,
            chunkDuration: Self.schedulingChunkDuration,
            startingAt: startFrame
        )
    }

    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private func reportFailure(_ error: Error, shouldResume: Bool = false) {
        cancelAudioConfigurationRecovery()
        completionWatchdogTask?.cancel()
        completionWatchdogTask = nil
        stopTimeline()
        if shouldResume {
            elapsed = currentPlaybackTime()
        }
        audioOutput.pause()
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
        mediaSession.configureRemoteCommands(
            supportedPlaybackRates: PlaybackRate.presets,
            backwardSkipInterval: backwardSkipInterval,
            forwardSkipInterval: forwardSkipInterval
        ) { [weak self] command in
            self?.handleRemoteCommand(command)
        }
    }

    private func handleRemoteCommand(_ command: PlaybackRemoteCommand) {
        switch command {
        case .play:
            play()
        case .pause:
            pause()
        case .togglePlayPause:
            if state == .playing {
                pause()
            } else {
                play()
            }
        case .stop:
            stop()
        case .nextTrack, .skipForward:
            skip(by: forwardSkipInterval)
        case .previousTrack, .skipBackward:
            skip(by: -backwardSkipInterval)
        case .seek(let position):
            seek(to: position)
        case .changePlaybackRate(let requestedRate):
            guard PlaybackRate.isSupported(requestedRate) else { return }
            rate = PlaybackRate.normalized(requestedRate)
        }
        onExternalControl?()
    }

    private func updateNowPlaying(throttleTimeline: Bool = false) {
        guard state != .idle else { return }
        let current = clock.now
        if throttleTimeline,
           let lastNowPlayingTimelineUpdate,
           lastNowPlayingTimelineUpdate.duration(to: current)
            < Self.nowPlayingThrottleInterval {
            return
        }
        lastNowPlayingTimelineUpdate = current
        let title = showTitleInNowPlaying && !currentTitle.isEmpty
            ? currentTitle
            : "Say It"
        mediaSession.publishNowPlaying(
            PlaybackNowPlayingInfo(
                title: title,
                duration: generatedDuration,
                elapsed: elapsed,
                playbackRate: state == .playing ? rate : 0
            )
        )
    }
}
