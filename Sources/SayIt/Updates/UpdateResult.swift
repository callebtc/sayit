import Foundation

enum UpdateResult: Sendable {
    case unconfigured
    case current
    case available(version: String, url: URL)
}
