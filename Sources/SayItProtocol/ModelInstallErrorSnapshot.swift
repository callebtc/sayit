import Foundation

public struct ModelInstallErrorSnapshot: Codable, Sendable, Equatable {
    public let modelID: String
    public let message: String

    public init(modelID: String, message: String) {
        self.modelID = modelID
        self.message = message
    }
}
