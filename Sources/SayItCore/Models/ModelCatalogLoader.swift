import Foundation

public struct ModelCatalogLoader: Sendable {
    public init() {}

    public func bundledCatalog() throws -> ModelCatalog {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ModelCatalogBundleToken.self)
        #endif
        guard let url = bundle.url(
            forResource: "ModelCatalog",
            withExtension: "json"
        ) else {
            throw ModelCatalogError.resourceMissing
        }
        return try load(from: url)
    }

    public func load(from url: URL) throws -> ModelCatalog {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        try validate(catalog)
        return catalog
    }

    public func validate(_ catalog: ModelCatalog) throws {
        guard catalog.schemaVersion == 1 else {
            throw ModelCatalogError.unsupportedSchema(catalog.schemaVersion)
        }

        var seen: Set<ModelID> = []
        var dependencyIDs: Set<String> = []
        for dependency in catalog.dependencies {
            guard dependencyIDs.insert(dependency.id).inserted,
                  isImmutableRevision(dependency.revision),
                  dependency.repository.split(separator: "/").count == 2,
                  !dependency.files.isEmpty else {
                throw ModelCatalogError.invalidModel(
                    ModelID(dependency.id),
                    reason: "invalid offline dependency"
                )
            }
        }
        for model in catalog.models {
            guard seen.insert(model.id).inserted else {
                throw ModelCatalogError.duplicateID(model.id)
            }
            guard isImmutableRevision(model.revision) else {
                throw ModelCatalogError.invalidRevision(model.id)
            }
            guard model.repository.split(separator: "/").count == 2 else {
                throw ModelCatalogError.invalidModel(
                    model.id,
                    reason: "repository must be owner/name"
                )
            }
            guard model.estimatedDiskBytes > 0,
                  model.estimatedPeakMemoryBytes > 0 else {
                throw ModelCatalogError.invalidModel(
                    model.id,
                    reason: "storage and memory estimates must be positive"
                )
            }
            if model.capabilities.requiresReferenceAudio && model.isSelectable {
                throw ModelCatalogError.invalidModel(
                    model.id,
                    reason: "reference-only models cannot be selected in version one"
                )
            }
        }
    }

    private func isImmutableRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }
}
