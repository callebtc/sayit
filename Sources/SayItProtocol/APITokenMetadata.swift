import Foundation

public struct APITokenMetadata: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let prefix: String
    public let scopes: Set<APITokenScope>
    public let createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID,
        name: String,
        prefix: String,
        scopes: Set<APITokenScope>,
        createdAt: Date,
        lastUsedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
