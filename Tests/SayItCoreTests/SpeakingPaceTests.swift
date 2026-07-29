import Testing
@testable import SayItCore

@Suite("Speaking pace")
struct SpeakingPaceTests {
    @Test("Pace presets are ordered from slower to faster")
    func presetsAreOrdered() {
        #expect(
            SpeakingPace.allCases.map(\.rawValue)
                == [0.75, 0.9, 1, 1.1, 1.25, 1.5]
        )
        #expect(SpeakingPace.natural.rawValue == 1)
    }
}
