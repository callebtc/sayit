import AVFoundation
import Foundation
import Testing
@testable import SayIt

@Suite("Audio archive")
struct AudioArchiveTests {
    @Test("Generated speech is saved as audible AAC")
    func generatedSpeechIsSavedAsAudibleAAC() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sampleRate = 24_000.0
        let samples = (0..<Int(sampleRate / 2)).map { frame in
            Float(sin(2 * .pi * 440 * Double(frame) / sampleRate) * 0.25)
        }
        let archive = AudioArchive(directory: directory)
        let result = try await archive.writeM4A(
            samples: samples,
            sampleRate: sampleRate,
            requestID: UUID()
        )
        let url = directory.appending(path: result.relativePath)
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCapacity = AVAudioFrameCount(file.length)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCapacity
            )
        )
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let decoded = UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)
        )
        let meanSquare = decoded.reduce(Double.zero) {
            $0 + Double($1 * $1)
        } / Double(decoded.count)

        #expect(result.byteCount > 0)
        #expect(abs(result.duration - 0.5) < 0.01)
        #expect(sqrt(meanSquare) > 0.01)
    }
}
