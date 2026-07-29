import Foundation

public enum TriggerSource: String, Codable, Sendable {
    case service
    case clipboard
    case history
    case preview
    case frontend
    case commandLine
    case http
}
