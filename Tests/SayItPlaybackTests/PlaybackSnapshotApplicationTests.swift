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

    @Test("Event revisions advance monotonically within one connection")
    func appliesMonotonicEventRevisions() {
        #expect(AppState.shouldApplyEvent(id: 12, after: 7))
        #expect(!AppState.shouldApplyEvent(id: 7, after: 7))
        #expect(!AppState.shouldApplyEvent(id: 6, after: 7))
        #expect(AppState.shouldApplyEvent(id: 6, after: nil))
    }

    @Test("Delayed service responses cannot replace newer state")
    func rejectsDelayedServiceResponses() {
        #expect(
            AppState.isServiceStateRequestCurrent(
                requestedRevision: 7,
                currentRevision: 7,
                requestedGeneration: 3,
                currentGeneration: 3
            )
        )
        #expect(
            !AppState.isServiceStateRequestCurrent(
                requestedRevision: 7,
                currentRevision: 8,
                requestedGeneration: 3,
                currentGeneration: 3
            )
        )
        #expect(
            !AppState.isServiceStateRequestCurrent(
                requestedRevision: 7,
                currentRevision: nil,
                requestedGeneration: 3,
                currentGeneration: 4
            )
        )
    }

    @Test("Playback refresh cadence follows visible playback surfaces")
    func playbackRefreshCadence() {
        #expect(
            AppState.playbackRefreshInterval(
                isPlaybackSurfacePresented: false
            ) == 1
        )
        #expect(
            AppState.playbackRefreshInterval(
                isPlaybackSurfacePresented: true
            ) == 0.25
        )
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
