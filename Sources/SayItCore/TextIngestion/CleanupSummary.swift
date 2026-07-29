import Foundation

public struct CleanupSummary: Codable, Equatable, Sendable {
    public let sourceFormat: String
    public let removedCodeBlocks: Int
    public let normalizedWhitespace: Bool

    public init(
        sourceFormat: String,
        removedCodeBlocks: Int = 0,
        normalizedWhitespace: Bool = false
    ) {
        self.sourceFormat = sourceFormat
        self.removedCodeBlocks = removedCodeBlocks
        self.normalizedWhitespace = normalizedWhitespace
    }
}
