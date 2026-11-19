@preconcurrency import AVFoundation
import Foundation

@MainActor
final class LivePlaybackAudioOutput: PlaybackAudioOutput {
    private final class ConfigurationObserverState: @unchecked Sendable {
        private let lock = NSLock()
        private var isReconfiguring = false
        private var observer: (any NSObjectProtocol)?

        func setReconfiguring(_ reconfiguring: Bool) {
            lock.withLock {
                isReconfiguring = reconfiguring
            }
        }

        func shouldForwardNotification() -> Bool {
            lock.withLock {
                !isReconfiguring
            }
        }

        func storeObserver(_ newObserver: any NSObjectProtocol) {
            let oldObserver = lock.withLock { () -> (any NSObjectProtocol)? in
                let previous = observer
                observer = newObserver
                return previous
            }
            if let oldObserver {
                NotificationCenter.default.removeObserver(oldObserver)
            }
        }

        func invalidate() {
            let current = lock.withLock { () -> (any NSObjectProtocol)? in
                let previous = observer
                observer = nil
                return previous
            }
            if let current {
                NotificationCenter.default.removeObserver(current)
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let observerState = ConfigurationObserverState()

    var onConfigurationChange: (@MainActor @Sendable () -> Void)?

    init() {
        engine.attach(player)
        let state = observerState
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard state.shouldForwardNotification() else { return }
            Task { @MainActor [weak self] in
                self?.onConfigurationChange?()
            }
        }
        observerState.storeObserver(observer)
    }

    deinit {
        observerState.invalidate()
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    func configureGraph(sampleRate: Double) throws {
        let format = try monoFormat(sampleRate: sampleRate)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
            throw PlaybackError.noOutputDevice
        }

        observerState.setReconfiguring(true)
        defer { observerState.setReconfiguring(false) }

        engine.stop()
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try ensureEngineRunning()
    }

    func ensureEngineRunning() throws {
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

    func play() {
        if !player.isPlaying {
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func stopPlayer() {
        player.stop()
    }

    func pauseEngine() {
        engine.pause()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func renderedPosition() -> PlaybackRenderPosition? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return nil
        }
        return PlaybackRenderPosition(
            frame: playerTime.sampleTime,
            sampleRate: playerTime.sampleRate
        )
    }

    func scheduleBuffer(
        _ samples: [Float],
        sampleRate: Double,
        completion: (@MainActor @Sendable () -> Void)?
    ) throws {
        let buffer = try makeBuffer(samples: samples, sampleRate: sampleRate)
        try validatePlayerFormat(for: buffer)
        if let completion {
            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { _ in
                Task { @MainActor in
                    completion()
                }
            }
        } else {
            player.scheduleBuffer(buffer)
        }
    }

    func openAudioFile(
        at url: URL,
        chunkFrameCount: Int
    ) throws -> any PlaybackAudioFileReading {
        guard url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw PlaybackError.unsupportedAudioFile
        }
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount > 0 else {
            throw PlaybackError.unsupportedAudioFile
        }
        let clampedChunkFrames = max(chunkFrameCount, 1)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(clampedChunkFrames)
        ) else {
            throw PlaybackError.unsupportedAudioFile
        }
        return LivePlaybackAudioFile(
            file: file,
            buffer: buffer,
            chunkFrameCount: clampedChunkFrames
        )
    }

    private func monoFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
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

    private func validatePlayerFormat(for buffer: AVAudioPCMBuffer) throws {
        let outputFormat = player.outputFormat(forBus: 0)
        guard outputFormat.channelCount == buffer.format.channelCount,
              abs(outputFormat.sampleRate - buffer.format.sampleRate) < 0.5 else {
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
        let format = try monoFormat(sampleRate: sampleRate)
        guard let buffer = AVAudioPCMBuffer(
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
}

@MainActor
private final class LivePlaybackAudioFile: PlaybackAudioFileReading {
    let sampleRate: Double
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let chunkFrameCount: Int

    init(
        file: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        chunkFrameCount: Int
    ) {
        self.file = file
        self.buffer = buffer
        self.chunkFrameCount = chunkFrameCount
        sampleRate = file.processingFormat.sampleRate
    }

    func readNextChunk() throws -> [Float]? {
        guard file.framePosition < file.length else { return nil }
        let remaining = file.length - file.framePosition
        let frameCount = AVAudioFrameCount(
            min(remaining, AVAudioFramePosition(chunkFrameCount))
        )
        try file.read(into: buffer, frameCount: frameCount)
        guard buffer.frameLength > 0 else { return nil }
        return try monoSamples(from: buffer)
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
}
