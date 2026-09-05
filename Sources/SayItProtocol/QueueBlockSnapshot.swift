import Foundation

public struct QueueBlockSnapshot: Codable, Sendable {
    public let reason: QueueBlockReason
    public let jobID: UUID?
    public let message: String

    public init(
        reason: QueueBlockReason,
        jobID: UUID? = nil,
        message: String
    ) {
        self.reason = reason
        self.jobID = jobID
        self.message = message
    }
}
