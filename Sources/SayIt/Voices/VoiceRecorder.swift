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
    private static let startupProbeDelay: Duration = .seconds(1)

    private var engine: AVAudioEngine?
    private var sink: VoiceRecordingSink?
    private var meterTask: Task<Void, Never>?
    private var startupRecoveryTask: Task<Void, Never>?
    private var recordingGeneration = 0

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
        recordingURL = nil
        let generation = recordingGeneration
        try startAttempt(destination: destination)
        scheduleStartupRecovery(
            destination: destination,
            generation: generation
        )
    }

    private func startAttempt(destination: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard (1...8).contains(hardwareFormat.channelCount),
              hardwareFormat.sampleRate.isFinite,
              (8_000...384_000).contains(hardwareFormat.sampleRate) else {
            access = .noDevice
            throw VoiceRecordingError.noAudioDevice
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let sink = VoiceRecordingSink(destination: destination)
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil,
            block: Self.tapHandler(for: sink)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.finish()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        self.engine = engine
        self.sink = sink
        recordingURL = destination
        isRecording = true
        level = 0
        peak = 0
        duration = 0
        startMetering()
    }

    private func startMetering() {
        meterTask?.cancel()
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

    private func scheduleStartupRecovery(
        destination: URL,
        generation: Int
    ) {
        // A cold macOS input can start without delivering live samples. Rebuild
        // it once after the device has had time to finish activating.
        startupRecoveryTask?.cancel()
        startupRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.startupProbeDelay)
            } catch {
                return
            }
            guard let self,
                  self.recordingGeneration == generation,
                  self.isRecording,
                  let reading = self.sink?.reading,
                  Self.needsStartupRecovery(
                    frameCount: reading.frameCount,
                    peak: reading.peak
                  ) else {
                return
            }
            self.startupRecoveryTask = nil
            self.restartAfterColdStartup(destination: destination)
        }
    }

    private func restartAfterColdStartup(destination: URL) {
        finishCurrentAttempt()
        do {
            try startAttempt(destination: destination)
        } catch {
            errorMessage = error.localizedDescription
            recordingURL = nil
            isRecording = false
            refreshAccess()
        }
    }

    nonisolated static func needsStartupRecovery(
        frameCount: AVAudioFramePosition,
        peak: Float
    ) -> Bool {
        frameCount == 0 || peak == 0
    }

    @discardableResult
    func stop() -> URL? {
        recordingGeneration &+= 1
        startupRecoveryTask?.cancel()
        startupRecoveryTask = nil
        let finalReading = finishCurrentAttempt()
        if let reading = finalReading {
            level = reading.level
            peak = reading.peak
            duration = reading.duration
            errorMessage = reading.errorMessage
        }
        let completedURL: URL? = if let finalReading,
                                    finalReading.frameCount > 0,
                                    finalReading.errorMessage == nil {
            recordingURL
        } else {
            nil
        }
        isRecording = false
        recordingURL = completedURL
        return completedURL
    }

    @discardableResult
    private func finishCurrentAttempt() -> VoiceRecordingSink.Reading? {
        meterTask?.cancel()
        meterTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let finalReading = sink?.finish()
        engine = nil
        sink = nil
        return finalReading
    }

    nonisolated static func tapHandler(
        for sink: VoiceRecordingSink
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            sink.consume(buffer)
        }
    }
}
