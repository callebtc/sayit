import AVFoundation

import Foundation
import PlaybackDSP
import SayItCore
import SayItProtocol

actor AudioArchive {
    private static let writeChunkFrameCount = 65_536
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func writeM4A(
        samples: [Float],
        sampleRate: Double,
        requestID: UUID
    ) throws -> AudioArchiveResult {
        let format = try monoFormat(sampleRate: sampleRate)
        return try writeM4A(
            requestID: requestID,
            sampleRate: sampleRate,
            frameCount: Int64(samples.count)
        ) { file in
            try write(samples: samples, format: format, to: file)
        }
    }

    func writeM4A(
        source: PCMStoreSnapshot,
        requestID: UUID
    ) throws -> AudioArchiveResult {
        let format = try monoFormat(sampleRate: source.sampleRate)
        return try writeM4A(
            requestID: requestID,
            sampleRate: source.sampleRate,
            frameCount: source.frameCount
        ) { file in
            try write(source: source, format: format, to: file)
        }
    }

    private func writeM4A(
        requestID: UUID,
        sampleRate: Double,
        frameCount: Int64,
        writeAudio: (AVAudioFile) throws -> Void
    ) throws -> AudioArchiveResult {
        let filename = "\(requestID.uuidString).m4a"
        let url = directory.appending(path: filename)
        let m4aStagingURL = directory.appending(
            path: "\(requestID.uuidString).partial.mp4"
        )
        let fileManager = FileManager.default

        try? fileManager.removeItem(at: m4aStagingURL)
        do {
            try writePCMMP4(
                sampleRate: sampleRate,
                destination: m4aStagingURL,
                writeAudio: writeAudio
            )
            try install(stagingURL: m4aStagingURL, destinationURL: url)
        } catch {
            try? fileManager.removeItem(at: m4aStagingURL)
            throw error
        }

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudioArchiveResult(
            relativePath: filename,
            byteCount: Int64(size),
            duration: Double(frameCount) / sampleRate
        )
    }

    func writeWAV(
        samples: [Float],
        sampleRate: Double,
        destination: URL
    ) throws {
        let format = try monoFormat(sampleRate: sampleRate)
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings
        )
        try write(samples: samples, format: format, to: file)
    }

    func writeWAV(
        source: PCMStoreSnapshot,
        destination: URL
    ) throws {
        let format = try monoFormat(sampleRate: source.sampleRate)
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings
        )
        try write(source: source, format: format, to: file)
    }

    func convertToWAV(source: URL, destination: URL, rate: Double = 1) throws {
        guard PlaybackRate.isSupported(rate) else {
            throw ServiceFailure(
                code: "export.invalid_rate",
                message: "Choose an export rate from \(PlaybackRate.minimum) to \(PlaybackRate.maximum)."
            )
        }
        let input = try AVAudioFile(
            forReading: source,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = input.processingFormat
        guard format.channelCount == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let stretch = try TimeStretchStream(sampleRate: format.sampleRate, rate: rate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: AVAudioFrameCount(Self.writeChunkFrameCount)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.processingFormat.settings
        )
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            let frameCount = AVAudioFrameCount(
                min(
                    remaining,
                    AVAudioFramePosition(Self.writeChunkFrameCount)
                )
            )
            try input.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            try Task.checkCancellation()
            guard let channel = buffer.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let samples = Array(UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
            let processed = try stretch.process(samples)
            if !processed.isEmpty {
                try write(samples: processed, format: format, to: output)
            }
        }
        let tail = try stretch.process([], final: true)
        if !tail.isEmpty {
            try write(samples: tail, format: format, to: output)
        }
    }

    func remove(relativePath: String) {
        let url = directory.appending(path: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    private func monoFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard sampleRate.isFinite,
              sampleRate > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return format
    }

    private func write(
        samples: [Float],
        format: AVAudioFormat,
        to file: AVAudioFile
    ) throws {
        guard !samples.isEmpty,
              samples.allSatisfy(\.isFinite),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Self.writeChunkFrameCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }

        var offset = 0
        while offset < samples.count {
            let frameCount = min(
                Self.writeChunkFrameCount,
                samples.count - offset
            )
            buffer.frameLength = AVAudioFrameCount(frameCount)
            samples.withUnsafeBufferPointer { source in
                guard let address = source.baseAddress else { return }
                channel.update(
                    from: address.advanced(by: offset),
                    count: frameCount
                )
            }
            try file.write(from: buffer)
            offset += frameCount
        }
    }

    private func write(
        source: PCMStoreSnapshot,
        format: AVAudioFormat,
        to file: AVAudioFile
    ) throws {
        guard source.frameCount > 0,
              source.sampleRate.isFinite,
              source.sampleRate > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var offset: Int64 = 0
        while offset < source.frameCount {
            let frameCount = min(
                Self.writeChunkFrameCount,
                Int(source.frameCount - offset)
            )
            let samples = try source.readFrames(
                startingAt: offset,
                count: frameCount
            )
            try write(samples: samples, format: format, to: file)
            offset += Int64(samples.count)
        }
    }

    private func install(stagingURL: URL, destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL
            )
        } else {
            try fileManager.moveItem(
                at: stagingURL,
                to: destinationURL
            )
        }
    }

    private func writePCMMP4(
        sampleRate: Double,
        destination: URL,
        writeAudio: (AVAudioFile) throws -> Void
    ) throws {
        try writePCMMP4Body(
            sampleRate: sampleRate,
            destination: destination,
            writeAudio: writeAudio
        )
        let verification = try AVAudioFile(forReading: destination)
        guard verification.length > 0,
              verification.processingFormat.channelCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func writePCMMP4Body(
        sampleRate: Double,
        destination: URL,
        writeAudio: (AVAudioFile) throws -> Void
    ) throws {
        let output = try AVAudioFile(
            forWriting: destination,
            settings: pcm16Settings(sampleRate: sampleRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try writeAudio(output)
    }

    private func pcm16Settings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
