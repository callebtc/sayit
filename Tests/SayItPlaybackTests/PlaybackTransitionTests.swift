import Foundation
import Testing
@testable import SayItBackend

@Suite("Playback transitions")
struct PlaybackTransitionTests {
    @Test("Model switch fade is short and reaches silence monotonically")
    @MainActor
    func modelSwitchFadeCurve() {
        #expect(
            PlaybackController.modelSwitchFadeDuration == .milliseconds(24)
        )
        #expect(PlaybackController.modelSwitchFadeStepCount == 8)

        let volumes = (0...PlaybackController.modelSwitchFadeStepCount)
            .map {
                PlaybackController.modelSwitchFadeVolume(
                    step: $0,
                    stepCount: PlaybackController.modelSwitchFadeStepCount
                )
            }

        #expect(volumes.first == 1)
        #expect(volumes.last == 0)
        #expect(
            zip(volumes, volumes.dropFirst()).allSatisfy { lhs, rhs in
                lhs >= rhs
            }
        )
    }

    @Test("Model switch fade clamps invalid steps")
    @MainActor
    func modelSwitchFadeClamping() {
        #expect(
            PlaybackController.modelSwitchFadeVolume(
                step: -1,
                stepCount: 8
            ) == 1
        )
        #expect(
            PlaybackController.modelSwitchFadeVolume(
                step: 9,
                stepCount: 8
            ) == 0
        )
        #expect(
            PlaybackController.modelSwitchFadeVolume(
                step: 1,
                stepCount: 0
            ) == 0
        )
    }
}
