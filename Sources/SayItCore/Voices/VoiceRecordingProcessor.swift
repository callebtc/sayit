@preconcurrency import AVFoundation
import Foundation

public struct VoiceRecordingProcessor: Sendable {
    private struct Recording {
        let samples: [Float]
        let sampleRate: Double
        let channelCount: Int
    }

    private static let silenceFloor: Float = 0.008
    private static let minimumRMS: Float = 0.004
    private static let clippingThreshold: Float = 0.995
    private static let maximumClippedFraction: Float = 0.005
    // Approximately -28 dBFS RMS, with enough headroom for natural speech peaks.
    private static let targetRMS: Float = 0.04
    private static let maximumNormalizationGain: Float = 10
    private static let normalizedPeakCeiling: Float = 0.95
    private static let canonicalGainTolerance: Float = 0.01

    public init() {}

    public func process(
        source: URL,
        destination: URL,
        targetSampleRate: Double,
        minimumDuration: TimeInterval,
        maximumDuration: TimeInterval
    ) throws -> VoiceRecordingAnalysis {
        try validateParameters(
            targetSampleRate: targetSampleRate,
            minimumDuration: minimumDuration,
            maximumDuration: maximumDuration
        )
        let recording = try readRecording(
            source: source,
            maximumDuration: maximumDuration
        )
        let mono = recording.samples
        let (rms, _) = try validatedLevels(in: mono)

        let threshold = max(Self.silenceFloor, rms * 0.12)
        guard let firstSignal = mono.firstIndex(where: {
            abs($0) >= threshold
        }),
        let lastSignal = mono.lastIndex(where: {
            abs($0) >= threshold
        }) else {
            throw VoiceRecordingError.silent
        }
        let padding = Int(recording.sampleRate * 0.1)
        let lower = max(0, firstSignal - padding)
        let upper = min(mono.count - 1, lastSignal + padding)
        let trimmed = Array(mono[lower...upper])
        let duration = Double(trimmed.count) / recording.sampleRate
        guard duration >= minimumDuration else {
            throw VoiceRecordingError.tooShort(minimum: minimumDuration)
        }
        guard duration <= maximumDuration else {
            throw VoiceRecordingError.tooLong(maximum: maximumDuration)
        }

        let resampled = resample(
            trimmed,
            from: recording.sampleRate,
            to: targetSampleRate
        )
        let normalized = normalizeLevel(resampled)
        try writeAtomically(
            samples: normalized.samples,
            sampleRate: targetSampleRate,
            destination: destination
        )
        return VoiceRecordingAnalysis(
            duration: Double(normalized.samples.count) / targetSampleRate,
            rootMeanSquare: normalized.rms,
            peak: normalized.peak,
            sampleRate: targetSampleRate
        )
    }

    public func validateProcessedReference(
        source: URL,
        destination: URL,
        targetSampleRate: Double,
        minimumDuration: TimeInterval,
        maximumDuration: TimeInterval
    ) throws -> VoiceRecordingAnalysis {
        try validateParameters(
            targetSampleRate: targetSampleRate,
            minimumDuration: minimumDuration,
            maximumDuration: maximumDuration
        )
        let recording = try readRecording(
            source: source,
            maximumDuration: maximumDuration
        )
        guard recording.channelCount == 1,
              abs(recording.sampleRate - targetSampleRate) < 1 else {
            throw VoiceRecordingError.outOfRange
        }
        let (rms, peak) = try validatedLevels(in: recording.samples)
        let duration = Double(recording.samples.count) / recording.sampleRate
        guard duration >= minimumDuration else {
            throw VoiceRecordingError.tooShort(minimum: minimumDuration)
        }
        guard duration <= maximumDuration else {
            throw VoiceRecordingError.tooLong(maximum: maximumDuration)
        }
        let expectedGain = normalizeLevel(recording.samples).gain
        guard abs(expectedGain - 1) <= Self.canonicalGainTolerance else {
            throw VoiceRecordingError.notProcessed
        }
        try copyAtomically(source: source, destination: destination)
        return VoiceRecordingAnalysis(
            duration: duration,
            rootMeanSquare: rms,
            peak: peak,
            sampleRate: recording.sampleRate
        )
    }

    private func validateParameters(
        targetSampleRate: Double,
        minimumDuration: TimeInterval,
        maximumDuration: TimeInterval
    ) throws {
        guard targetSampleRate.isFinite,
              (8_000...192_000).contains(targetSampleRate),
              minimumDuration.isFinite,
              maximumDuration.isFinite,
              minimumDuration >= 0,
              maximumDuration >= minimumDuration,
              maximumDuration <= 60 else {
            throw VoiceRecordingError.outOfRange
        }
    }

    private func readRecording(
        source: URL,
        maximumDuration: TimeInterval
    ) throws -> Recording {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw VoiceRecordingError.unreadable
        }
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        let sourceChannels = sourceFormat.channelCount
        guard file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max),
              (1...8).contains(sourceChannels),
              sourceRate.isFinite,
              (8_000...384_000).contains(sourceRate),
              Double(file.length) / sourceRate
                <= max(maximumDuration + 30, 60) else {
            throw VoiceRecordingError.outOfRange
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else {
            throw VoiceRecordingError.unreadable
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw VoiceRecordingError.unreadable
        }
        guard buffer.frameLength > 0,
              let channels = buffer.floatChannelData else {
            throw VoiceRecordingError.unreadable
        }

        let count = Int(buffer.frameLength)
        let channelCount = Int(sourceChannels)
        var mono = [Float](repeating: 0, count: count)
        for channelIndex in 0..<channelCount {
            for sampleIndex in 0..<count {
                mono[sampleIndex] += channels[channelIndex][sampleIndex]
                    / Float(channelCount)
            }
        }
        return Recording(
            samples: mono,
            sampleRate: sourceRate,
            channelCount: channelCount
        )
    }

    private func validatedLevels(
        in samples: [Float]
    ) throws -> (rms: Float, peak: Float) {
        guard samples.allSatisfy(\.isFinite) else {
            throw VoiceRecordingError.nonFinite
        }
        let (rms, peak) = levels(in: samples)
        guard rms >= Self.minimumRMS, peak >= Self.silenceFloor else {
            throw VoiceRecordingError.silent
        }
        let clippedCount = samples.lazy.filter {
            abs($0) >= Self.clippingThreshold
        }.count
        guard Float(clippedCount) / Float(samples.count)
                <= Self.maximumClippedFraction else {
            throw VoiceRecordingError.clipped
        }
        return (rms, peak)
    }

    private func levels(in samples: [Float]) -> (rms: Float, peak: Float) {
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        let rms = Float(
            sqrt(
                samples.reduce(0.0) {
                    $0 + Double($1) * Double($1)
                } / Double(samples.count)
            )
        )
        return (rms, peak)
    }

    private func normalizeLevel(
        _ samples: [Float]
    ) -> (samples: [Float], rms: Float, peak: Float, gain: Float) {
        let (rms, peak) = levels(in: samples)
        let targetGain = Self.targetRMS / rms
        let peakLimitedGain = Self.normalizedPeakCeiling / peak
        let gain = min(
            targetGain,
            peakLimitedGain,
            Self.maximumNormalizationGain
        )
        let normalized = samples.map { $0 * gain }
        let normalizedLevels = levels(in: normalized)
        return (
            normalized,
            normalizedLevels.rms,
            normalizedLevels.peak,
            gain
        )
    }

    private func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard abs(sourceRate - targetRate) >= 1 else { return samples }
        let outputCount = max(
            Int(Double(samples.count) * targetRate / sourceRate),
            1
        )
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * sourceRate / targetRate
            let lower = min(Int(sourcePosition), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction)
                + samples[upper] * fraction
        }
    }

    private func writeAtomically(
        samples: [Float],
        sampleRate: Double,
        destination: URL
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceRecordingError.unreadable
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        do {
            let output = try AVAudioFile(
                forWriting: staging,
                settings: format.settings
            )
            let chunkSize = 65_536
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunkSize)
            ),
            let channel = pcm.floatChannelData?[0] else {
                throw VoiceRecordingError.unreadable
            }
            var offset = 0
            while offset < samples.count {
                let count = min(chunkSize, samples.count - offset)
                pcm.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(
                        from: source.baseAddress!.advanced(by: offset),
                        count: count
                    )
                }
                try output.write(from: pcm)
                offset += count
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging
                )
            } else {
                try FileManager.default.moveItem(
                    at: staging,
                    to: destination
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if let recordingError = error as? VoiceRecordingError {
                throw recordingError
            }
            throw VoiceRecordingError.unreadable
        }
    }

    private func copyAtomically(source: URL, destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw VoiceRecordingError.unreadable
        }
    }
}
