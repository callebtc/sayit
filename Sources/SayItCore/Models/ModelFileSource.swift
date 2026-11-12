import Foundation

/// A pinned source for a file distributed separately from the model weights.
public struct ModelFileSource: Codable, Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let path: String

    public init(repository: String, revision: String, path: String) {
        self.repository = repository
        self.revision = revision
        self.path = path
    }
}
