import Foundation
import SayItCore
import Testing
@testable import SayItBackend

struct SpeechAudioCollectorTests {
    @Test("Silent collection joins matching chunks and removes its temporary audio")
    func collectsAudio() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItCollectorTests")
        defer { fixture.remove() }
        let id = UUID()
        var collector: SpeechAudioCollector? = SpeechAudioCollector(requestID: id, directory: fixture.root)
        try collector?.append(chunk(id: UUID(), samples: [9]))
        try collector?.append(chunk(id: id, samples: [0.1, 0.2]))
        try collector?.append(chunk(id: id, samples: [0.3]))
        let source = try #require(try collector?.snapshot())
        #expect(source.sampleRate == 24_000)
        #expect(try source.readFrames(startingAt: 0, count: 3) == [0.1, 0.2, 0.3])
        collector = nil
        #expect(!FileManager.default.fileExists(atPath: source.url.path))
    }

    @Test("Silent collection rejects empty audio, invalid samples, and format changes")
    func rejectsInvalidAudio() throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItCollectorTests")
        defer { fixture.remove() }
        let id = UUID()
        let collector = SpeechAudioCollector(requestID: id, directory: fixture.root)
        #expect(throws: SynthesisError.self) { try collector.snapshot() }
        for samples in [[], [Float.nan], [Float.infinity]] {
            #expect(throws: (any Error).self) {
                try collector.append(chunk(id: id, samples: samples))
            }
        }
        for rate in [0, -1, Double.nan, Double.infinity, 48_000] {
            #expect(throws: (any Error).self) {
                try collector.append(chunk(id: id, samples: [0.1], sampleRate: rate))
            }
        }
    }

    private func chunk(id: UUID, samples: [Float], sampleRate: Double = 24_000) -> AudioChunk {
        AudioChunk(requestID: id, index: 0, samples: samples,
                   sampleRate: sampleRate, startsParagraph: false)
    }
}
