@preconcurrency import AVFoundation
import Foundation

final class VoiceRecordingSink: @unchecked Sendable {
    struct Reading: Sendable {
        let level: Float
        let peak: Float
        let duration: TimeInterval
        let frameCount: AVAudioFramePosition
        let errorMessage: String?
    }

    private let destination: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var recordingFormat: AVAudioFormat?
    private var sampleRate: Double = 1
    private var frames: AVAudioFramePosition = 0
    private var currentLevel: Float = 0
    private var currentPeak: Float = 0
    private var writeError: String?
    private var isFinished = false

    init(destination: URL) {
        self.destination = destination
    }

    var reading: Reading {
        lock.withLock {
            makeReading()
        }
    }

    @discardableResult
    func finish() -> Reading {
        lock.withLock {
            isFinished = true
            file = nil
            return makeReading()
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let levels = Self.levels(in: buffer)
        lock.withLock {
            guard !isFinished, writeError == nil else { return }
            do {
                let output = try outputFile(for: buffer.format)
                try output.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                currentLevel = levels.level
                currentPeak = max(currentPeak, levels.peak)
            } catch {
                writeError = Self.message(for: error)
                file = nil
            }
        }
    }

    private func outputFile(for format: AVAudioFormat) throws -> AVAudioFile {
        guard format.sampleRate.isFinite,
              (8_000...384_000).contains(format.sampleRate),
              (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw SinkError.unsupportedFormat
        }
        if let file, let recordingFormat {
            guard abs(recordingFormat.sampleRate - format.sampleRate) < 1,
                  recordingFormat.channelCount == format.channelCount,
                  recordingFormat.commonFormat == format.commonFormat,
                  recordingFormat.isInterleaved == format.isInterleaved else {
                throw SinkError.formatChanged
            }
            return file
        }
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.file = file
        recordingFormat = format
        sampleRate = format.sampleRate
        return file
    }

    private func makeReading() -> Reading {
        Reading(
            level: currentLevel,
            peak: currentPeak,
            duration: Double(frames) / sampleRate,
            frameCount: frames,
            errorMessage: writeError
        )
    }

    private static func levels(
        in buffer: AVAudioPCMBuffer
    ) -> (level: Float, peak: Float) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0,
              channelCount > 0,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData else {
            return (0, 0)
        }
        var sum: Double = 0
        var peak: Float = 0
        for channelIndex in 0..<channelCount {
            for index in 0..<frameCount {
                let value = channels[channelIndex][index]
                sum += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
        }
        let divisor = frameCount * channelCount
        return (Float(sqrt(sum / Double(divisor))), peak)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SinkError.unsupportedFormat:
            "The microphone supplied an unsupported audio format. Reconnect it, wait a moment, and record again."
        case SinkError.formatChanged:
            "The microphone changed audio format while recording. Wait for it to reconnect, then record again."
        default:
            "The microphone recording could not be saved. Check available disk space and try again."
        }
    }

    private enum SinkError: Error {
        case unsupportedFormat
        case formatChanged
    }
}
