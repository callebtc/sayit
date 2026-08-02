import Foundation

public struct ModelExperience: Codable, Equatable, Sendable {
    public enum Size: String, Codable, Sendable {
        case small
        case medium
        case large

        public var displayName: String {
            rawValue.capitalized
        }
    }

    public enum Speed: String, Codable, Sendable {
        case fast
        case mediumFast = "medium-fast"
        case medium
        case mediumSlow = "medium-slow"
        case slow

        public var displayName: String {
            switch self {
            case .fast: "Fast"
            case .mediumFast: "Medium-fast"
            case .medium: "Medium"
            case .mediumSlow: "Medium-slow"
            case .slow: "Slow"
            }
        }
    }

    public let recommendationRank: Int
    public let size: Size
    public let speed: Speed
    public let note: String?

    public init(
        recommendationRank: Int,
        size: Size,
        speed: Speed,
        note: String? = nil
    ) {
        self.recommendationRank = recommendationRank
        self.size = size
        self.speed = speed
        self.note = note
    }
}
