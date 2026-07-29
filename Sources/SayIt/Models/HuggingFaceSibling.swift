import Foundation

struct HuggingFaceSibling: Decodable, Sendable {
    let rfilename: String
    let size: Int64?
    let lfs: HuggingFaceLFSInfo?
}
