import Foundation

public enum SelectionServiceRequest: Codable, Equatable, Sendable {
    case authorizationStatus
    case requestAuthorization
    case selectedText
}
