import Testing
@testable import SayItBackend

@Suite("Playback controller calculations")
struct PlaybackControllerBoundaryTests {
    @Test("Playback buffer duration grows only above normal speed")
    @MainActor
    func preferredBufferDuration() {
        #expect(PlaybackController.preferredStartBufferDuration(for: -1) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 0.5) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 1) == 1.2)
        #expect(
            abs(
                PlaybackController.preferredStartBufferDuration(for: 1.5)
                    - 1.8
            ) < 0.000_001
        )
    }

    @Test("Model-switch fade clamps progress and reaches silence")
    @MainActor
    func fadeVolume() {
        #expect(
            PlaybackController.modelSwitchFadeVolume(step: -1, stepCount: 8)
                == 1
        )
        #expect(
            PlaybackController.modelSwitchFadeVolume(step: 4, stepCount: 8)
                == 0.5
        )
        #expect(
            PlaybackController.modelSwitchFadeVolume(step: 9, stepCount: 8)
                == 0
        )
        #expect(
            PlaybackController.modelSwitchFadeVolume(step: 1, stepCount: 0)
                == 0
        )
    }
}
