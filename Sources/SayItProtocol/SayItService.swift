import Foundation

@MainActor
public protocol SayItService: Sendable {
    func handle(_ request: ServiceRequest) async -> ServiceResponse
    func events(after sequence: UInt64) async -> [ServiceEvent]
}
