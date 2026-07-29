import Foundation

public enum ModelStability: String, Codable, CaseIterable, Sendable {
    case recommended
    case stable
    case experimental
    case unavailable
}
