import AVFoundation
import Foundation
import Testing
@testable import SayItBackend

@Suite("Backend audio archive", .serialized)
struct BackendAudioArchiveTests {
    @Test("WAV export changes duration while preserving pitch and source audio", arguments: [0.75, 1.0, 1.2, 2.0])
    func exportSpeed(rate: Double) async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItExportTests")
        defer { fixture.remove() }
        let archive = AudioArchive(directory: fixture.root)
        let sampleRate = 24_000.0
        let samples = (0..<72_000).map {
            Float(0.2 * sin(2 * .pi * 220 * Double($0) / sampleRate))
        }
        let source = try await archive.writeM4A(
            samples: samples, sampleRate: sampleRate, requestID: UUID()
        )
        let url = fixture.root.appending(path: source.relativePath)
        let original = try Data(contentsOf: url)
        let outputURL = fixture.root.appending(path: "export.wav")
        try await archive.convertToWAV(source: url, destination: outputURL, rate: rate)
        let output = try AVAudioFile(forReading: outputURL)
        #expect(output.processingFormat.sampleRate == sampleRate)
        #expect(output.length == Int64((Double(samples.count) / rate).rounded()))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(output.length)
        ))
        try output.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let middle = Array(UnsafeBufferPointer(
            start: channel.advanced(by: 6_000), count: Int(buffer.frameLength) - 12_000
        ))
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) * sampleRate / Double(middle.count)
        #expect(abs(frequency - 220) < 3)
        #expect(middle.allSatisfy { $0.isFinite })
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("WAV round trips and archive removal are deterministic")
    func roundTrips() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItAudioArchiveTests"
        )
        defer { fixture.remove() }
        let archive = AudioArchive(directory: fixture.root)
        let sampleRate = 24_000.0
        let samples = (0..<12_000).map { frame in
            Float(sin(2 * .pi * 220 * Double(frame) / sampleRate) * 0.2)
        }
        let wav = fixture.root.appending(path: "source.wav")
        try await archive.writeWAV(
            samples: samples,
            sampleRate: sampleRate,
            destination: wav
        )
        let converted = fixture.root.appending(path: "converted.wav")
        try await archive.convertToWAV(
            source: wav,
            destination: converted
        )
        #expect(
            try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                > 0
        )

        let removablePath = "removable.audio"
        let removableURL = fixture.root.appending(path: removablePath)
        try Data([1, 2, 3]).write(to: removableURL)
        await archive.remove(relativePath: removablePath)
        #expect(
            !FileManager.default.fileExists(atPath: removableURL.path)
        )
        await archive.remove(relativePath: "already-missing.m4a")
    }

    @Test("Invalid formats and samples fail before persisting audio")
    func invalidInput() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItAudioArchiveTests"
        )
        defer { fixture.remove() }
        let archive = AudioArchive(directory: fixture.root)

        for rate in [0, -1, Double.nan, Double.infinity] {
            await #expect(throws: (any Error).self) {
                try await archive.writeWAV(
                    samples: [0],
                    sampleRate: rate,
                    destination: fixture.root.appending(
                        path: "\(UUID().uuidString).wav"
                    )
                )
            }
        }
        for samples in [[], [Float.nan], [Float.infinity]] {
            await #expect(throws: (any Error).self) {
                try await archive.writeWAV(
                    samples: samples,
                    sampleRate: 24_000,
                    destination: fixture.root.appending(
                        path: "\(UUID().uuidString).wav"
                    )
                )
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await archive.writeM4A(
                samples: [],
                sampleRate: 24_000,
                requestID: UUID()
            )
        }
        await #expect(throws: (any Error).self) {
            try await archive.convertToWAV(
                source: fixture.root.appending(path: "missing.wav"),
                destination: fixture.root.appending(path: "output.wav")
            )
        }
        for rate in [0, -1, 99, Double.nan, Double.infinity] {
            await #expect(throws: (any Error).self) {
                try await archive.convertToWAV(
                    source: fixture.root.appending(path: "source.wav"),
                    destination: fixture.root.appending(path: "output.wav"), rate: rate
                )
            }
        }
    }
}
