import Foundation

struct HealthResponse: Codable, Sendable {
    let status: String
    let protocolVersion: Int
}
