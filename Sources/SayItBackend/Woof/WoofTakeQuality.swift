import Foundation

/// Scores one sampled Woof utterance so a failed take can be drawn again.
///
/// A take fails when it pauses for a second or more between its first and
/// last voiced moments, or when it runs far longer than its text needs.
/// Lower scores are better; failures sort after every acceptable take.
struct WoofTakeQuality: Comparable {
    static let maximumPause: Double = 1
    // Woof leaves up to about a second of silence around each take.
    private static let paddingMilliseconds = 1_500
    private static let millisecondsPerCharacter = 95
    private static let frameMilliseconds = 40
    private static let frameDuration: Double = 0.04
    private static let silenceThreshold: Float = -50

    let failureCount: Int
    let longestPause: Double
    let secondsPerCharacter: Double

    var isAcceptable: Bool {
        failureCount == 0
    }

    init(samples: [Float], sampleRate: Int, characterCount: Int, reachedEnd: Bool) {
        longestPause = Self.longestPause(in: samples, sampleRate: sampleRate)
        let milliseconds = samples.count * 1_000 / max(sampleRate, 1)
        secondsPerCharacter = Double(milliseconds) / 1_000 / Double(max(characterCount, 1))
        // A runaway that never ended ranks below a finished take that is only long.
        failureCount = (longestPause >= Self.maximumPause ? 1 : 0)
            + (milliseconds > Self.maximumMilliseconds(characterCount: characterCount) ? 1 : 0)
            + (reachedEnd ? 0 : 1)
    }

    /// The longest take that passes.
    static func maximumMilliseconds(characterCount: Int) -> Int {
        paddingMilliseconds + millisecondsPerCharacter * characterCount
    }

    /// Frames after which a take is a runaway. Twice the passing length keeps a
    /// slow but complete take whole; the extra frame lets a take that ends on
    /// the last frame report its end.
    static func frameLimit(characterCount: Int) -> Int {
        2 * maximumMilliseconds(characterCount: characterCount) / frameMilliseconds + 1
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.failureCount, lhs.longestPause, lhs.secondsPerCharacter)
            < (rhs.failureCount, rhs.longestPause, rhs.secondsPerCharacter)
    }

    /// The longest run of quiet 40 ms frames inside the voiced span, in seconds.
    static func longestPause(in samples: [Float], sampleRate: Int) -> Double {
        let frameLength = Int(Double(sampleRate) * frameDuration)
        let frameCount = samples.count / max(frameLength, 1)
        guard frameLength > 0, frameCount >= 3 else { return 0 }
        let quiet = (0..<frameCount).map { frame in
            let range = (frame * frameLength)..<((frame + 1) * frameLength)
            let power = samples[range].reduce(0) { $0 + $1 * $1 } / Float(frameLength)
            return 20 * log10(power.squareRoot() + 1e-9) < silenceThreshold
        }
        guard let first = quiet.firstIndex(of: false),
              let last = quiet.lastIndex(of: false), first < last else {
            return 0
        }
        var longest = 0
        var current = 0
        for isQuiet in quiet[first...last] {
            current = isQuiet ? current + 1 : 0
            longest = max(longest, current)
        }
        return Double(longest * frameLength) / Double(sampleRate)
    }
}
