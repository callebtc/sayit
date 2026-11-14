import Foundation

enum WoofModelError: LocalizedError, Equatable {
    case invalidWeights(String)
    case unknownVoice(String)
    case inputTooLong

    var errorDescription: String? {
        switch self {
        case .invalidWeights(let detail):
            "The Underdog Woof weights could not be loaded: \(detail)."
        case .unknownVoice(let voice):
            "Underdog Woof has no voice named \(voice)."
        case .inputTooLong:
            "Input too long for one Underdog Woof utterance."
        }
    }
}
