import Foundation

public enum SelectionServiceResponse: Codable, Equatable, Sendable {
    case authorizationStatus(isTrusted: Bool)
    case selectedText(String)
    case authorizationRequired
    case noSelection
    case selectionTooLong(maximumCharacters: Int)
    case unavailable
}
