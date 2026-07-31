import AVFoundation

import Foundation
import SayItCore

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
        let filename = "\(requestID.uuidString).m4a"
        let url = directory.appending(path: filename)
        let stagingURL = directory.appending(
            path: "\(requestID.uuidString).partial.m4a"
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let fileManager = FileManager.default

        try? fileManager.removeItem(at: stagingURL)
        do {
            let file = try AVAudioFile(
                forWriting: stagingURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try write(samples: samples, format: format, to: file)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: stagingURL
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudioArchiveResult(
            relativePath: filename,
            byteCount: Int64(size),
            duration: Double(samples.count) / sampleRate
        )
    }

    func writeM4A(
        source: PCMStoreSnapshot,
        requestID: UUID
    ) throws -> AudioArchiveResult {
        let format = try monoFormat(sampleRate: source.sampleRate)
        let filename = "\(requestID.uuidString).m4a"
        let url = directory.appending(path: filename)
        let stagingURL = directory.appending(
            path: "\(requestID.uuidString).partial.m4a"
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let fileManager = FileManager.default

        try? fileManager.removeItem(at: stagingURL)
        do {
            let file = try AVAudioFile(
                forWriting: stagingURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try write(source: source, format: format, to: file)
            try install(stagingURL: stagingURL, destinationURL: url)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudioArchiveResult(
            relativePath: filename,
            byteCount: Int64(size),
            duration: Double(source.frameCount) / source.sampleRate
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

    func convertToWAV(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
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
            try output.write(from: buffer)
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
}
