import Foundation
import Testing
@testable import SayItCore

@Suite("Playback rate")
struct PlaybackRateTests {
    @Test("Presets span the supported range in even steps")
    func presetsSpanRange() {
        #expect(PlaybackRate.presets.first == PlaybackRate.minimum)
        #expect(PlaybackRate.presets.last == PlaybackRate.maximum)
        #expect(PlaybackRate.presets.contains(PlaybackRate.normal))
        #expect(PlaybackRate.presets == PlaybackRate.presets.sorted())
        for (slower, faster) in zip(
            PlaybackRate.presets,
            PlaybackRate.presets.dropFirst()
        ) {
            #expect(abs(faster - slower - PlaybackRate.step * 2) < 1e-9)
        }
        for preset in PlaybackRate.presets {
            #expect(PlaybackRate.normalized(preset) == preset)
            #expect(PlaybackRate.isSupported(preset))
        }
    }

    @Test("Clamping bounds the range and rejects non-finite rates")
    func clampingBoundsRange() {
        #expect(PlaybackRate.clamped(0.1) == PlaybackRate.minimum)
        #expect(PlaybackRate.clamped(3) == PlaybackRate.maximum)
        #expect(PlaybackRate.clamped(1.35) == 1.35)
        #expect(PlaybackRate.clamped(.nan) == PlaybackRate.normal)
        #expect(PlaybackRate.clamped(.infinity) == PlaybackRate.normal)
        #expect(!PlaybackRate.isSupported(.nan))
        #expect(!PlaybackRate.isSupported(2.01))
        #expect(!PlaybackRate.isSupported(0.49))
    }

    @Test("Normalizing snaps to the nearest fine step")
    func normalizingSnapsToStep() {
        #expect(PlaybackRate.normalized(1.33) == 1.35)
        #expect(PlaybackRate.normalized(1.32) == 1.3)
        #expect(PlaybackRate.normalized(1.05) == 1.05)
        #expect(PlaybackRate.normalized(0.4) == PlaybackRate.minimum)
        #expect(PlaybackRate.normalized(2.4) == PlaybackRate.maximum)
    }

    @Test("Stepping moves by one increment and stops at the bounds")
    func steppingStaysInRange() {
        #expect(PlaybackRate.adjusted(1, bySteps: 1) == 1.05)
        #expect(PlaybackRate.adjusted(1, bySteps: -1) == 0.95)
        #expect(PlaybackRate.adjusted(1.33, bySteps: 1) == 1.4)
        #expect(
            PlaybackRate.adjusted(PlaybackRate.maximum, bySteps: 1)
                == PlaybackRate.maximum
        )
        #expect(
            PlaybackRate.adjusted(PlaybackRate.minimum, bySteps: -1)
                == PlaybackRate.minimum
        )
    }

    @Test("Matching tolerates float drift but separates neighboring steps")
    func matchingToleratesDrift() {
        #expect(PlaybackRate.matches(1.35, 0.5 + 17 * 0.05))
        #expect(PlaybackRate.matches(1.3, Double(Float(1.3))))
        #expect(!PlaybackRate.matches(1.3, 1.35))
    }

    @Test("Formatting trims trailing zeros and marks the speed")
    func formattingIsCompact() {
        #expect(PlaybackRate.formatted(1) == "1×")
        #expect(PlaybackRate.formatted(1.5).hasSuffix("5×"))
        #expect(PlaybackRate.formatted(1.35).hasSuffix("35×"))
    }
}
