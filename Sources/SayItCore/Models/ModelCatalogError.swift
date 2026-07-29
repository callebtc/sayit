import Foundation

public enum ModelCatalogError: LocalizedError, Equatable {
    case resourceMissing
    case unsupportedSchema(Int)
    case duplicateID(ModelID)
    case invalidRevision(ModelID)
    case invalidModel(ModelID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "The bundled model catalog is missing."
        case .unsupportedSchema(let version):
            "Model catalog schema \(version) is not supported."
        case .duplicateID(let id):
            "The model catalog contains duplicate ID \(id.rawValue)."
        case .invalidRevision(let id):
            "Model \(id.rawValue) is not pinned to an immutable revision."
        case .invalidModel(let id, let reason):
            "Model \(id.rawValue) is invalid: \(reason)"
        }
    }
}
