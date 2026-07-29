import Foundation

public struct ModelDownloadProgress: Codable, Equatable, Sendable {
    public let modelID: ModelID
    public let state: ModelInstallationState
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Int64

    public init(
        modelID: ModelID,
        state: ModelInstallationState,
        completedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Int64
    ) {
        self.modelID = modelID
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}
