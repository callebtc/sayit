import Testing
@testable import SayItBackend

@Suite("Underdog Woof take quality")
struct WoofTakeQualityTests {
    private let sampleRate = 24_000

    private func audio(_ segments: [(seconds: Double, level: Float)]) -> [Float] {
        segments.flatMap { segment in
            [Float](repeating: segment.level, count: Int(segment.seconds * Double(sampleRate)))
        }
    }

    @Test("Pauses count only between the first and last voiced frames")
    func measuresInternalPauses() {
        let quietEdges = audio([(0.5, 0), (0.4, 0.1), (0.3, 0), (0.4, 0.1), (2, 0)])
        #expect(abs(WoofTakeQuality.longestPause(in: quietEdges, sampleRate: sampleRate) - 0.28) < 0.05)
        #expect(WoofTakeQuality.longestPause(in: audio([(1, 0)]), sampleRate: sampleRate) == 0)
        #expect(WoofTakeQuality.longestPause(in: [0.1, 0.1], sampleRate: sampleRate) == 0)
    }

    @Test("Stalled and overlong takes fail and sort after acceptable takes")
    func scoresTakes() {
        let speech = audio([(0.6, 0.1), (0.2, 0), (0.6, 0.1)])
        let good = WoofTakeQuality(samples: speech, sampleRate: sampleRate, characterCount: 20, reachedEnd: true)
        let stalled = WoofTakeQuality(
            samples: audio([(0.6, 0.1), (1.2, 0), (0.6, 0.1)]),
            sampleRate: sampleRate, characterCount: 40, reachedEnd: true
        )
        let overlong = WoofTakeQuality(
            samples: audio([(1.5, 0.1), (0.2, 0), (1.5, 0.1)]),
            sampleRate: sampleRate, characterCount: 10, reachedEnd: true
        )
        let shortWord = WoofTakeQuality(
            samples: audio([(0.4, 0), (0.4, 0.1), (0.4, 0)]),
            sampleRate: sampleRate, characterCount: 4, reachedEnd: true
        )
        // 1.88 s is exactly the 4-character budget: 1.5 s + 4 × 0.095 s.
        let atBudget = WoofTakeQuality(
            samples: audio([(0.5, 0), (0.88, 0.1), (0.5, 0)]),
            sampleRate: sampleRate, characterCount: 4, reachedEnd: true
        )
        let unfinished = WoofTakeQuality(samples: speech, sampleRate: sampleRate, characterCount: 20, reachedEnd: false)

        #expect(good.isAcceptable)
        #expect(shortWord.isAcceptable)
        #expect(atBudget.isAcceptable)
        #expect(WoofTakeQuality.frameLimit(characterCount: 4) == 95)
        #expect(!stalled.isAcceptable)
        #expect(!overlong.isAcceptable)
        #expect(!unfinished.isAcceptable)
        #expect([stalled, overlong, good].min() == good)
        let runaway = WoofTakeQuality(
            samples: audio([(3, 0.1)]), sampleRate: sampleRate, characterCount: 10, reachedEnd: false
        )
        #expect(overlong < runaway)
        #expect(overlong < WoofTakeQuality(
            samples: audio([(0.6, 0.1), (1.2, 0), (0.6, 0.1)]),
            sampleRate: sampleRate, characterCount: 10, reachedEnd: false
        ))
    }
}
