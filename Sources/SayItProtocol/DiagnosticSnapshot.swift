import Foundation

public struct DiagnosticSnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: String
    public let category: String
    public let code: String

    public init(
        id: UUID,
        timestamp: Date,
        severity: String,
        category: String,
        code: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.code = code
    }
}
