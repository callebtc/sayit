import Foundation


struct AudioArchiveResult: Sendable {
    let relativePath: String
    let byteCount: Int64
    let duration: TimeInterval
}
