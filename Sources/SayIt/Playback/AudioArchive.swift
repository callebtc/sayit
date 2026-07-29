import AVFoundation
import Foundation
import SayItCore

actor AudioArchive {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func writeM4A(
        samples: [Float],
        sampleRate: Double,
        requestID: UUID
    ) throws -> AudioArchiveResult {
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
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress else { return }
            channel.update(from: address, count: samples.count)
        }

        let filename = "\(requestID.uuidString).m4a"
        let url = directory.appending(path: filename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudioArchiveResult(
            relativePath: filename,
            byteCount: Int64(size),
            duration: Double(samples.count) / sampleRate
        )
    }

    func writeWAV(
        samples: [Float],
        sampleRate: Double,
        destination: URL
    ) throws {
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
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress else { return }
            channel.update(from: address, count: samples.count)
        }
        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings
        )
        try file.write(from: buffer)
    }

    func convertToWAV(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let capacity = AVAudioFrameCount(input.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: capacity
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try input.read(into: buffer)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.processingFormat.settings
        )
        try output.write(from: buffer)
    }
}
