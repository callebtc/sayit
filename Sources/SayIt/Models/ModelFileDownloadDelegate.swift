import Foundation
import SayItCore

final class ModelFileDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    typealias ProgressHandler = @Sendable (ModelDownloadProgress) async -> Void

    private let modelID: ModelID
    private let baseCompletedBytes: Int64
    private let totalModelBytes: Int64
    private let startedAt = ContinuousClock.now
    private let progress: ProgressHandler

    init(
        modelID: ModelID,
        baseCompletedBytes: Int64,
        totalModelBytes: Int64,
        progress: @escaping ProgressHandler
    ) {
        self.modelID = modelID
        self.baseCompletedBytes = baseCompletedBytes
        self.totalModelBytes = totalModelBytes
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let elapsed = startedAt.duration(to: .now)
        let seconds = max(
            Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            0.001
        )
        let completed = baseCompletedBytes + totalBytesWritten
        let event = ModelDownloadProgress(
            modelID: modelID,
            state: .downloading,
            completedBytes: completed,
            totalBytes: totalModelBytes,
            bytesPerSecond: Int64(Double(totalBytesWritten) / seconds)
        )
        Task {
            await progress(event)
        }
        _ = session
        _ = downloadTask
        _ = bytesWritten
        _ = totalBytesExpectedToWrite
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        _ = session
        _ = downloadTask
        _ = location
    }
}
