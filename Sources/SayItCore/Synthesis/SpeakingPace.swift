import Foundation

public enum SpeakingPace: Double, CaseIterable, Identifiable, Sendable {
    case slower = 0.75
    case slow = 0.9
    case natural = 1
    case brisk = 1.1
    case fast = 1.25
    case faster = 1.5

    public var id: Double { rawValue }
}
