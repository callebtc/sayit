import Foundation


enum SynthesisError: LocalizedError {
    case modelNotInstalled
    case generatedNoAudio
    case invalidReferenceAudio
    case speakingPaceUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            "The selected voice model is not installed."
        case .generatedNoAudio:
            "The voice model did not generate playable audio."
        case .invalidReferenceAudio:
            "The saved voice reference could not be read."
        case .speakingPaceUnavailable:
            "The selected voice model could not apply its speaking pace."
        }
    }
}
