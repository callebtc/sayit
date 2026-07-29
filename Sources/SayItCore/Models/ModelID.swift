import Foundation

public struct ModelID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}
