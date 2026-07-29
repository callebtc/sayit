import Foundation

public enum TextIngestionError: LocalizedError, Equatable {
    case noReadableText
    case textTooLong(limit: Int)
    case invalidRepresentation

    public var errorDescription: String? {
        switch self {
        case .noReadableText:
            "No readable text was found."
        case .textTooLong(let limit):
            "The text is longer than the \(limit)-character limit."
        case .invalidRepresentation:
            "The selected text format could not be read."
        }
    }
}
