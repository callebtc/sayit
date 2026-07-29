import Foundation

public struct APITokenCreation: Codable, Sendable {
    public let metadata: APITokenMetadata
    public let secret: String

    public init(metadata: APITokenMetadata, secret: String) {
        self.metadata = metadata
        self.secret = secret
    }
}
