import Foundation

public struct ModelDependencyDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let modelTypes: [String]
    public let repository: String
    public let revision: String
    public let targetSubdirectory: String
    public let files: [ModelFileDescriptor]

    public init(
        id: String,
        modelTypes: [String],
        repository: String,
        revision: String,
        targetSubdirectory: String,
        files: [ModelFileDescriptor]
    ) {
        self.id = id
        self.modelTypes = modelTypes
        self.repository = repository
        self.revision = revision
        self.targetSubdirectory = targetSubdirectory
        self.files = files
    }
}
