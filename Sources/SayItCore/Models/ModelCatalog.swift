import Foundation

public struct ModelCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let dependencies: [ModelDependencyDescriptor]
    public let models: [ModelDescriptor]

    public init(
        schemaVersion: Int,
        generatedAt: String,
        dependencies: [ModelDependencyDescriptor] = [],
        models: [ModelDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.dependencies = dependencies
        self.models = models
    }
}
