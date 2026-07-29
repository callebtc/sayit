import Foundation

public struct ExportedFile: Codable, Sendable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}
