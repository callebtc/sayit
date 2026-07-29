import Foundation

public enum SpeechJobSource: String, Codable, Sendable {
    case frontend
    case commandLine
    case http
    case service
    case clipboard
    case history
    case preview
}
