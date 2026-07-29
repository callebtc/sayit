import Foundation


struct HuggingFaceLFSInfo: Decodable, Sendable {
    let sha256: String
    let size: Int64
}
