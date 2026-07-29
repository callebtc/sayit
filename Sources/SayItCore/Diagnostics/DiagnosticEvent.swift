import Foundation

public struct DiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let category: DiagnosticCategory
    public let code: String
    public let modelID: ModelID?
    public let durationMilliseconds: Int?
    public let byteCount: Int64?
    public let numericValue: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        code: String,
        modelID: ModelID? = nil,
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
