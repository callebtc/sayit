import Foundation

public struct CleanedText: Codable, Equatable, Sendable {
    public let text: String
    public let title: String
    public let characterCount: Int
    public let detectedLanguage: String?
    public let cleanupSummary: CleanupSummary
    public let requiresLongTextConfirmation: Bool

    /// Character offsets of list items after cleanup.
    /// Optional so older stored records remain decodable.
    public let listItemStartOffsets: [Int]?

    public init(
        text: String,
        title: String,
        detectedLanguage: String?,
        cleanupSummary: CleanupSummary,
        requiresLongTextConfirmation: Bool,
        listItemStartOffsets: [Int]? = nil
    ) {
        self.text = text
        self.title = title
        characterCount = text.count
        self.detectedLanguage = detectedLanguage
        self.cleanupSummary = cleanupSummary
        self.requiresLongTextConfirmation = requiresLongTextConfirmation
        self.listItemStartOffsets = listItemStartOffsets
    }
}
