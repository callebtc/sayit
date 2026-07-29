import Foundation
import SayItProtocol

struct APITokenRecord: Codable, Sendable {
    var metadata: APITokenMetadata
    let digest: Data
}
