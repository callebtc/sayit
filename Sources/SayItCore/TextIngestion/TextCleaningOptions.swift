import Foundation

public struct TextCleaningOptions: Equatable, Sendable {
    public var isEnabled: Bool
    public var stripMarkdown: Bool
    public var stripHTML: Bool
    public var stripCodeBlocks: Bool
    public var stripSpecialCharacters: Bool
    public var normalizeWhitespace: Bool

    public init(
        isEnabled: Bool = true,
        stripMarkdown: Bool = true,
        stripHTML: Bool = true,
        stripCodeBlocks: Bool = true,
        stripSpecialCharacters: Bool = true,
        normalizeWhitespace: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.stripMarkdown = stripMarkdown
        self.stripHTML = stripHTML
        self.stripCodeBlocks = stripCodeBlocks
        self.stripSpecialCharacters = stripSpecialCharacters
        self.normalizeWhitespace = normalizeWhitespace
    }
}
