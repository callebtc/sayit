import SayItProtocol
import Testing
@testable import SayIt

@Suite("Playback snapshot application")
@MainActor
struct PlaybackSnapshotApplicationTests {
    @Test("Timeline-only snapshots retain static playback content")
    func retainsContent() {
        let controller = PlaybackController()
        controller.apply(
            PlaybackSnapshot(
                state: "playing",
                elapsed: 1,
                generatedDuration: 10,
                estimatedDuration: 12,
                currentTitle: "Article",
                modelID: "model-a",
                amplitudes: [0.1, 0.2],
                spokenText: "Hello world",
                spokenChunks: [
                    PlaybackTextChunk(
                        textStart: 0,
                        textEnd: 11,
                        audioStart: 0
                    )
                ],
                contentRevision: 4
            )
        )

        controller.apply(
            PlaybackSnapshot(
                state: "playing",
                elapsed: 2,
                generatedDuration: 10,
                estimatedDuration: 12,
                contentRevision: 4,
                includesContent: false
            )
        )

        #expect(controller.elapsed == 2)
        #expect(controller.currentTitle == "Article")
        #expect(controller.modelID?.rawValue == "model-a")
        #expect(controller.amplitudes == [0.1, 0.2])
        #expect(controller.spokenText == "Hello world")
        #expect(controller.spokenChunks.count == 1)
    }

    @Test("Coalesced service revisions are monotonically accepted")
    func acceptsCoalescedRevisions() {
        #expect(AppState.shouldApplyEvent(id: 12, after: 7))
        #expect(!AppState.shouldApplyEvent(id: 7, after: 7))
        #expect(!AppState.shouldApplyEvent(id: 6, after: 7))
    }
}
