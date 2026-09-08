import Foundation

/// Bounds, stepping, and formatting for listening speed, shared by the
/// playback menu, settings, and system media controls.
public enum PlaybackRate {
    public static let minimum = 0.5
    public static let maximum = 2.0
    public static let normal = 1.0

    /// Smallest adjustment the interface exposes.
    public static let step = 0.05

    /// Rates offered as one-tap choices, two fine steps apart.
    public static let presets: [Double] = {
        let presetStep = step * 2
        let count = Int(((maximum - minimum) / presetStep).rounded())
        return (0...count).map { normalized(minimum + Double($0) * presetStep) }
    }()

    /// Tolerates binary floating-point drift when comparing rates that came
    /// from different sources, such as a slider and a system media control.
    private static let comparisonTolerance = 0.001

    public static func isSupported(_ value: Double) -> Bool {
        value.isFinite && (minimum...maximum).contains(value)
    }

    /// Clamps a rate into the supported range, falling back to normal speed
    /// for values that are not finite.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return normal }
        return min(max(value, minimum), maximum)
    }

    /// Clamps a rate and snaps it to the nearest step.
    public static func normalized(_ value: Double) -> Double {
        let stepped = (clamped(value) / step).rounded() * step
        return (stepped * 100).rounded() / 100
    }

    /// Moves a rate by whole steps, staying inside the supported range.
    public static func adjusted(_ value: Double, bySteps steps: Int) -> Double {
        normalized(normalized(value) + Double(steps) * step)
    }

    /// True when two rates describe the same speed at display precision.
    public static func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < comparisonTolerance
    }

    public static func formatted(_ value: Double) -> String {
        let rate = value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(rate)×"
    }
}
