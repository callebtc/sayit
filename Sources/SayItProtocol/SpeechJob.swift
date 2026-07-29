import Foundation

public struct SpeechJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let source: SpeechJobSource
    public var title: String
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var state: SpeechJobState
    public var progress: Double
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        source: SpeechJobSource,
        title: String,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        state: SpeechJobState = .queued,
        progress: Double = 0,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.progress = progress
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
