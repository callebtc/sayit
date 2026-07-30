@preconcurrency import AVFoundation
import Foundation
import Observation
import SayItCore

enum VoiceMicrophoneAccess: Equatable {
    case unknown
    case requesting
    case granted
    case denied
    case restricted
    case noDevice

    var symbol: String {
        switch self {
        case .unknown, .requesting:
            "mic.badge.plus"
        case .granted:
            "mic"
        case .denied, .restricted:
            "mic.slash"
        case .noDevice:
            "cable.connector.slash"
        }
    }
}

@MainActor
@Observable
final class VoiceRecorder {
    private var engine: AVAudioEngine?
    private var sink: VoiceRecordingSink?
    private var meterTask: Task<Void, Never>?

    private(set) var access = VoiceMicrophoneAccess.unknown
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    private(set) var duration: TimeInterval = 0
    private(set) var recordingURL: URL?
    private(set) var errorMessage: String?

    init() {
        refreshAccess()
    }

    func refreshAccess() {
        access = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .unknown
        @unknown default:
            .restricted
        }
    }

    func requestAccess() async -> Bool {
        refreshAccess()
        if access == .granted { return true }
        guard access == .unknown else { return false }
        access = .requesting
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshAccess()
        return granted
    }

    func start(destination: URL) throws {
        guard access == .granted else {
            throw VoiceRecordingError.noAudioDevice
        }
        stop()
        errorMessage = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            access = .noDevice
            throw VoiceRecordingError.noAudioDevice
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sink = VoiceRecordingSink(file: file, sampleRate: format.sampleRate)
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, _ in
            sink.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.sink = sink
        recordingURL = destination
        isRecording = true
        level = 0
        peak = 0
        duration = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let reading = self.sink?.reading else {
                    return
                }
                self.level = reading.level
                self.peak = reading.peak
                self.duration = reading.duration
                if let message = reading.errorMessage {
                    self.errorMessage = message
                    self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    @discardableResult
    func stop() -> URL? {
        meterTask?.cancel()
        meterTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let reading = sink?.reading {
            level = reading.level
            peak = reading.peak
            duration = reading.duration
            errorMessage = reading.errorMessage
        }
        engine = nil
        sink = nil
        isRecording = false
        return recordingURL
    }
}

private final class VoiceRecordingSink: @unchecked Sendable {
    struct Reading {
        let level: Float
        let peak: Float
        let duration: TimeInterval
        let errorMessage: String?
    }

    private let file: AVAudioFile
    private let sampleRate: Double
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    private var currentLevel: Float = 0
    private var currentPeak: Float = 0
    private var writeError: String?

    init(file: AVAudioFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
    }

    var reading: Reading {
        lock.lock()
        defer { lock.unlock() }
        return Reading(
            level: currentLevel,
            peak: currentPeak,
            duration: Double(frames) / sampleRate,
            errorMessage: writeError
        )
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        var sum: Double = 0
        var peak: Float = 0
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if let channels = buffer.floatChannelData, frameCount > 0 {
            for channelIndex in 0..<channelCount {
                for index in 0..<frameCount {
                    let value = channels[channelIndex][index]
                    sum += Double(value) * Double(value)
                    peak = max(peak, abs(value))
                }
            }
        }
        let divisor = max(frameCount * channelCount, 1)
        let rms = Float(sqrt(sum / Double(divisor)))
        lock.lock()
        defer { lock.unlock() }
        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            currentLevel = rms
            currentPeak = max(currentPeak, peak)
        } catch {
            writeError = "The microphone recording could not be saved. Check available disk space and try again."
        }
    }
}
