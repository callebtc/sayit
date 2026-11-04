import Foundation

enum Drama3Error: LocalizedError {
    case invalidInput(String)
    case emptyAudio
    case generationLimit

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): return detail
        case .emptyAudio: return "Drama 3 did not generate audio. Try a different text or voice reference."
        case .generationLimit: return "Drama 3 reached its generation limit. Try shorter text chunks."
        }
    }
}
