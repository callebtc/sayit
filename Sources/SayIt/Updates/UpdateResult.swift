import Foundation

enum UpdateResult: Equatable, Sendable {
    case unconfigured
    case noPublishedRelease
    case current
    case available(version: String, url: URL)
}
