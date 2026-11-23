import Foundation
import SayItCore

/// One drawable state of the menu bar icon.
enum MenuBarIconFrame: Equatable, Sendable {
    /// The logo with each sound wave (mouth outward) at the given opacity.
    case waves(opacities: [Double])
    /// The head alone with a spinner cut out of it, rotated by `turns`
    /// (0 to 1 is one full clockwise revolution).
    case spinner(turns: Double)

    static let still = MenuBarIconFrame.waves(opacities: [1, 1, 1])
}

/// What the menu bar icon shows for the current playback state.
enum MenuBarIconAnimation: Equatable, Sendable {
    /// The static logo.
    case still
    /// Audio is being generated and nothing is audible yet: spinner.
    case processing
    /// Audio is playing: the waves light up from the mouth outward.
    case speaking

    init(playbackState: PlaybackState) {
        switch playbackState {
        case .preparing, .buffering:
            self = .processing
        case .playing:
            self = .speaking
        case .idle, .paused, .finished, .failed:
            self = .still
        }
    }

    var isAnimated: Bool {
        self != .still
    }

    var frameCount: Int {
        switch self {
        case .still: 1
        case .processing: 16
        case .speaking: 18
        }
    }

    /// Delay between frames; one loop takes `frameCount * frameInterval`.
    var frameInterval: Duration {
        switch self {
        case .still: .zero
        case .processing: .milliseconds(60)
        case .speaking: .milliseconds(70)
        }
    }

    /// The frame to show when motion is reduced.
    var reducedMotionFrame: MenuBarIconFrame {
        switch self {
        case .still, .speaking: .still
        case .processing: .spinner(turns: 0)
        }
    }

    var frames: [MenuBarIconFrame] {
        (0..<frameCount).map(frame(at:))
    }

    func frame(at index: Int) -> MenuBarIconFrame {
        let progress = Double(index % frameCount) / Double(frameCount)
        switch self {
        case .still:
            return .still
        case .processing:
            return .spinner(turns: progress)
        case .speaking:
            return .waves(opacities: (0..<3).map { wave in
                Self.cascadeOpacity(at: progress - Double(wave) * Self.cascadeStagger)
            })
        }
    }

    static let dimWaveOpacity = 0.25
    private static let cascadeStagger = 1.0 / 6.0

    /// Each wave brightens quickly, then fades back while the next one lights.
    private static func cascadeOpacity(at phase: Double) -> Double {
        let phase = phase - phase.rounded(.down)
        let rise = 0.2
        let fall = 0.65
        let level: Double
        if phase < rise {
            level = phase / rise
        } else if phase < fall {
            level = 1 - (phase - rise) / (fall - rise)
        } else {
            level = 0
        }
        return dimWaveOpacity + (1 - dimWaveOpacity) * level
    }
}
