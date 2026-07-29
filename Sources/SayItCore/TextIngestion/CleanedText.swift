import Foundation

public struct CleanedText: Codable, Equatable, Sendable {
    public let text: String
    public let title: String
    public let characterCount: Int
    public let detectedLanguage: String?
    public let cleanupSummary: CleanupSummary
    public let requiresLongTextConfirmation: Bool

    public init(
        text: String,
        title: String,
        detectedLanguage: String?,
        cleanupSummary: CleanupSummary,
        requiresLongTextConfirmation: Bool
    ) {
        self.text = text
        self.title = title
        characterCount = text.count
        self.detectedLanguage = detectedLanguage
        self.cleanupSummary = cleanupSummary
        self.requiresLongTextConfirmation = requiresLongTextConfirmation
    }
}
