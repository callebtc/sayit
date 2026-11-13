import SayItProtocol
import Testing
@testable import SayIt

@Suite("Playback snapshot application")
@MainActor
struct PlaybackSnapshotApplicationTests {
    @Test("Waveform and timing suffix updates preserve text and earlier anchors")
    func independentPayloads() {
        let controller = PlaybackController()
        let first = PlaybackTextChunk(textStart: 0, textEnd: 5, audioStart: 0)
        controller.apply(PlaybackSnapshot(
            spokenText: "first second", spokenChunks: [first]
        ))
        controller.apply(PlaybackSnapshot(
            amplitudes: [0.5], includesContent: false, includesWaveform: true
        ))
        #expect(controller.spokenText == "first second")
        #expect(controller.spokenChunks == [first])
        #expect(controller.amplitudes == [0.5])
        let finalized = PlaybackTextChunk(textStart: 0, textEnd: 5, audioStart: 0, audioEnd: 2)
        let next = PlaybackTextChunk(textStart: 6, textEnd: 12, audioStart: 3)
        controller.apply(PlaybackSnapshot(
            spokenChunks: [finalized, next], includesContent: false, includesTiming: true
        ))
        let nextFinal = PlaybackTextChunk(textStart: 6, textEnd: 12, audioStart: 3, audioEnd: 6)
        controller.apply(PlaybackSnapshot(
            spokenChunks: [nextFinal], includesContent: false,
            includesTiming: true, timingStartIndex: 1
        ))
        #expect(controller.spokenChunks == [finalized, nextFinal])
        #expect(controller.spokenText == "first second")
        #expect(controller.amplitudes == [0.5])
        controller.apply(PlaybackSnapshot(
            spokenChunks: [], includesContent: false,
            includesTiming: true, timingStartIndex: 0
        ))
        #expect(controller.spokenChunks.isEmpty)
        controller.apply(PlaybackSnapshot(
            spokenChunks: [next], includesContent: false,
            includesTiming: true, timingStartIndex: 4
        ))
        #expect(controller.spokenChunks.isEmpty)
    }

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
                ]
            )
        )

        controller.apply(
            PlaybackSnapshot(
                state: "playing",
                elapsed: 2,
                generatedDuration: 10,
                estimatedDuration: 12,
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


    @Test("Ribbon animation pauses while hidden or fully generated")
    func ribbonAnimationVisibilityPolicy() {
        #expect(
            VoiceRibbonView.shouldPauseTimeline(
                isPresented: false,
                isProcessing: true
            )
        )
        #expect(
            VoiceRibbonView.shouldPauseTimeline(
                isPresented: true,
                isProcessing: false
            )
        )
        #expect(
            !VoiceRibbonView.shouldPauseTimeline(
                isPresented: true,
                isProcessing: true
            )
        )
    }

    @Test("Completed onboarding stays dismissed without requiring a model")
    func completedOnboardingStaysDismissed() {
        #expect(
            !AppState.shouldPresentOnboarding(onboardingComplete: true)
        )
        #expect(AppState.shouldPresentOnboarding(onboardingComplete: false))
    }

    @Test("Successful playback dismisses a stale presented error")
    func successfulPlaybackDismissesPresentedError() {
        #expect(
            AppState.shouldDismissPresentedError(
                serviceError: nil,
                playbackState: "playing"
            )
        )
        #expect(
            !AppState.shouldDismissPresentedError(
                serviceError: nil,
                playbackState: "preparing"
            )
        )
        #expect(
            !AppState.shouldDismissPresentedError(
                serviceError: "Playback failed",
                playbackState: "playing"
            )
        )
    }

    @Test("Volume edits send commands while snapshot application stays silent")
    func volumeCommandsAndSnapshotSync() {
        let controller = PlaybackController()
        var commands: [ServiceCommand] = []
        controller.commandHandler = { commands.append($0) }

        controller.volume = 1.4
        #expect(commands.count == 1)

        controller.apply(
            PlaybackSnapshot(state: "playing", volume: 0.6)
        )
        #expect(controller.volume == 0.6)
        #expect(commands.count == 1)
    }
}
