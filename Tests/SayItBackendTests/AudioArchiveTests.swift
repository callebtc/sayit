import AVFoundation
import Foundation
import Testing
@testable import SayItBackend

@Suite("Backend audio archive", .serialized)
struct BackendAudioArchiveTests {
    @Test("WAV and M4A round trips produce nonempty finite-duration files")
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

        let requestID = UUID()
        let first = try await archive.writeM4A(
            samples: samples,
            sampleRate: sampleRate,
            requestID: requestID
        )
        let second = try await archive.writeM4A(
            samples: Array(samples.reversed()),
            sampleRate: sampleRate,
            requestID: requestID
        )
        #expect(first.relativePath == second.relativePath)
        #expect(second.byteCount > 0)
        #expect(abs(second.duration - 0.5) < 0.001)

        await archive.remove(relativePath: second.relativePath)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appending(path: second.relativePath).path
            )
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
    }
}
