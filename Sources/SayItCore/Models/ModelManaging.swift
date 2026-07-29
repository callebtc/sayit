import Foundation

public protocol ModelManaging: Sendable {
    func models() async -> [ModelDescriptor]
    func install(_ id: ModelID) async throws
    func cancelInstall(_ id: ModelID) async
    func remove(_ id: ModelID) async throws
    func select(_ id: ModelID) async throws
}
