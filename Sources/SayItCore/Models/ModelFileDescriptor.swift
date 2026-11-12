import Foundation

public struct ModelFileDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let byteCount: Int64
    public let sha256: String?
    public let source: ModelFileSource?

    public init(
        path: String, byteCount: Int64, sha256: String?,
        source: ModelFileSource? = nil
    ) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.source = source
    }
}
