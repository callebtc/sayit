import Foundation

public struct SpeechChunk: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let startsParagraph: Bool

    public init(id: Int, text: String, startsParagraph: Bool) {
        self.id = id
        self.text = text
        self.startsParagraph = startsParagraph
    }
}
