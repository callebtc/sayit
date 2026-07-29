import Foundation

public struct ModelLicense: Codable, Equatable, Sendable {
    public let identifier: String
    public let url: URL
    public let commercialUseAllowed: Bool
    public let requiresAcceptance: Bool

    public init(
        identifier: String,
        url: URL,
        commercialUseAllowed: Bool,
        requiresAcceptance: Bool
    ) {
        self.identifier = identifier
        self.url = url
        self.commercialUseAllowed = commercialUseAllowed
        self.requiresAcceptance = requiresAcceptance
    }
}
