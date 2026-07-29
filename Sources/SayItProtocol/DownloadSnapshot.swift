import Foundation

public struct DownloadSnapshot: Codable, Sendable {
    public let modelID: String
    public let state: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public init(
        modelID: String,
        state: String,
        completedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double
    ) {
        self.modelID = modelID
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}
