import Foundation

public struct TextSourcePayload: Sendable {
    public let source: TriggerSource
    public let html: Data?
    public let richText: Data?
    public let plainText: String?

    public init(
        source: TriggerSource,
        html: Data? = nil,
        richText: Data? = nil,
        plainText: String? = nil
    ) {
        self.source = source
        self.html = html
        self.richText = richText
        self.plainText = plainText
    }
}
