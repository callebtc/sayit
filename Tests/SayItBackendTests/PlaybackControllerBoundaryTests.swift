import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Playback controller boundaries", .serialized)
@MainActor
struct PlaybackControllerBoundaryTests {
    @Test("Empty playback lifecycle remains safe and reversible")
    func emptyLifecycle() async {
        let controller = PlaybackController()
        controller.rate = 1.5
        controller.backwardSkipInterval = 7
        controller.forwardSkipInterval = 42
        controller.showTitleInNowPlaying = true
        controller.prepare(
            requestID: UUID(),
            title: "Prepared",
            estimatedDuration: 10
        )
        #expect(controller.state == .preparing)
        #expect(controller.currentTitle == "Prepared")
        #expect(controller.estimatedDuration == 10)
        #expect(!controller.shouldStartWhenBuffered)

        controller.setSpokenText("First sentence.")
        controller.appendSpokenChunk(
            PlaybackTextChunk(
                textStart: 0,
                textEnd: 15,
                audioStart: 0
            )
        )
        #expect(controller.spokenText == "First sentence.")
        #expect(controller.spokenChunks.count == 1)
        controller.play()
        controller.pause()
        controller.seek(to: 5)
        controller.skip(by: 5)
        controller.finishBuffering()

        let archive = AudioArchive(
            directory: FileManager.default.temporaryDirectory
        )
        await #expect(throws: SynthesisError.self) {
            _ = try await controller.archive(using: archive)
        }
        await #expect(throws: SynthesisError.self) {
            try await controller.exportWAV(
                to: FileManager.default.temporaryDirectory.appending(
                    path: "\(UUID().uuidString).wav"
                ),
                using: archive
            )
        }

        controller.stop()
        #expect(controller.state == .idle)
        #expect(controller.currentTitle.isEmpty)
        #expect(controller.spokenText.isEmpty)
        #expect(controller.spokenChunks.isEmpty)
    }

    @Test("Malformed chunks are rejected without starting the audio engine")
    func malformedChunks() throws {
        let controller = PlaybackController()
        let requestID = UUID()
        controller.prepare(
            requestID: requestID,
            title: "Invalid chunks",
            estimatedDuration: 1
        )

        try controller.enqueue(
            AudioChunk(
                requestID: UUID(),
                index: 0,
                samples: [],
                sampleRate: 0,
                startsParagraph: true
            )
        )
        #expect(controller.generatedDuration == 0)

        for chunk in [
            AudioChunk(
                requestID: requestID,
                index: 0,
                samples: [],
                sampleRate: 24_000,
                startsParagraph: true
            ),
            AudioChunk(
                requestID: requestID,
                index: 0,
                samples: [0],
                sampleRate: 0,
                startsParagraph: true
            ),
            AudioChunk(
                requestID: requestID,
                index: 0,
                samples: [Float.nan],
                sampleRate: 24_000,
                startsParagraph: true
            )
        ] {
            #expect(throws: PlaybackError.self) {
                try controller.enqueue(chunk)
            }
        }
        #expect(throws: (any Error).self) {
            try controller.playFile(
                at: URL(filePath: "/definitely/missing/audio.wav"),
                title: "Missing"
            )
        }
        controller.stop()
    }
}
