import Foundation


struct HuggingFaceModelResponse: Decodable, Sendable {
    let sha: String
    let siblings: [HuggingFaceSibling]
    let cardData: HuggingFaceCardData?
}
