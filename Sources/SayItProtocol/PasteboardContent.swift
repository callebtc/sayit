import Foundation

public struct PasteboardContent: Codable, Equatable, Sendable {
    public let html: Data?
    public let richText: Data?
    public let plainText: String?

    public init(
        html: Data? = nil,
        richText: Data? = nil,
        plainText: String? = nil
    ) {
        self.html = html
        self.richText = richText
        self.plainText = plainText
    }
}
