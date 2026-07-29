import Foundation

public struct ServiceRequest: Codable, Identifiable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let command: ServiceCommand

    public init(
        id: UUID = UUID(),
        protocolVersion: Int = SayItProtocolVersion.current,
        command: ServiceCommand
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.command = command
    }
}
