import Foundation

public struct ServiceEvent: Codable, Identifiable, Sendable {
    public let id: UInt64
    public let snapshot: ServiceSnapshot

    public init(id: UInt64, snapshot: ServiceSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}
