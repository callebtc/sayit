import CryptoKit
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

    public func dependencyFingerprint(for model: ModelDescriptor) -> String? {
        Self.dependencyFingerprint(
            modelType: model.modelType,
            dependencies: dependencies
        )
    }

    public static func dependencyFingerprint(
        modelType: String,
        dependencies: [ModelDependencyDescriptor]
    ) -> String? {
        let modelType = modelType.lowercased()
        let matching = dependencies
            .filter { $0.modelTypes.contains(modelType) }
            .sorted { $0.id < $1.id }
        guard !matching.isEmpty else { return nil }
        let canonical = matching.map { dependency in
            let files = dependency.files.sorted { $0.path < $1.path }.map {
                "\($0.path):\($0.byteCount):\($0.sha256 ?? "-")"
            }.joined(separator: ",")
            return [
                dependency.id,
                dependency.repository,
                dependency.revision,
                dependency.targetSubdirectory,
                files
            ].joined(separator: ":")
        }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
