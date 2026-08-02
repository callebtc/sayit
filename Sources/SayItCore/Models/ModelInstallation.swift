import Foundation

public struct ModelInstallation: Codable, Equatable, Sendable {
    public let modelID: ModelID
    public let revision: String
    public let installedBytes: Int64
    public let verifiedAt: Date
    public let dependenciesVerifiedAt: Date?
    public let dependenciesFingerprint: String?
    public let relativePath: String

    public init(
        modelID: ModelID,
        revision: String,
        installedBytes: Int64,
        verifiedAt: Date,
        dependenciesVerifiedAt: Date? = nil,
        dependenciesFingerprint: String? = nil,
        relativePath: String
    ) {
        self.modelID = modelID
        self.revision = revision
        self.installedBytes = installedBytes
        self.verifiedAt = verifiedAt
        self.dependenciesVerifiedAt = dependenciesVerifiedAt
        self.dependenciesFingerprint = dependenciesFingerprint
        self.relativePath = relativePath
    }
}
