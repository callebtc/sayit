import Foundation

struct APIProblem: Codable, Sendable {
    let type: String
    let title: String
    let status: Int
    let detail: String
    let code: String
}
