import Foundation

public enum InputFormat: String, Codable, CaseIterable, Sendable {
    case plainText
    case markdown
    case html
    case richText
    case ssml
}
