import Foundation

struct HTTPAPIError: Error, Sendable {
    let status: Int
    let code: String
    let message: String
}
