import Foundation

public struct DiagnosticSnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: String
    public let category: String
    public let code: String
    public let modelID: String?
    public let durationMilliseconds: Int?
    public let byteCount: Int64?
    public let numericValue: Double?

    public init(
        id: UUID,
        timestamp: Date,
        severity: String,
        category: String,
        code: String,
        modelID: String? = nil,
        durationMilliseconds: Int? = nil,
        byteCount: Int64? = nil,
        numericValue: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.code = code
        self.modelID = modelID
        self.durationMilliseconds = durationMilliseconds
        self.byteCount = byteCount
        self.numericValue = numericValue
    }
}
