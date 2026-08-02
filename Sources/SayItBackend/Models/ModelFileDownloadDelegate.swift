import Foundation

import SayItCore

final class ModelFileDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    typealias ProgressHandler = @Sendable (ModelDownloadProgress) async -> Void

    private let modelID: ModelID
    private let baseCompletedBytes: Int64
    private let totalModelBytes: Int64
    private let progress: ProgressHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedFileURL: URL?
    private var resumeDataURL: URL?
    private var transferError: Error?
    private var isCancelled = false
    private var speedMeter = DownloadSpeedMeter()

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

    func download(
        using session: URLSession,
        request: URLRequest,
        resumeData: Data?,
        to downloadedFileURL: URL,
        resumeDataURL: URL
    ) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let downloadSession = URLSession(
                    configuration: session.configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = if let resumeData {
                    downloadSession.downloadTask(withResumeData: resumeData)
                } else {
                    downloadSession.downloadTask(with: request)
                }

                lock.withLock {
                    self.continuation = continuation
                    self.downloadSession = downloadSession
                    downloadTask = task
                    self.downloadedFileURL = downloadedFileURL
                    self.resumeDataURL = resumeDataURL
                }
                task.resume()

                if Task.isCancelled {
                    cancel()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return downloadTask
        }
        task?.cancel { [weak self] resumeData in
            self?.saveResumeData(resumeData)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let speed = lock.withLock { () -> Int64? in
            speedMeter.record(totalBytes: totalBytesWritten)
                ? speedMeter.bytesPerSecond
                : nil
        }
        guard let speed else { return }
        let completed = baseCompletedBytes + totalBytesWritten
        let event = ModelDownloadProgress(
            modelID: modelID,
            state: .downloading,
            completedBytes: completed,
            totalBytes: totalModelBytes,
            bytesPerSecond: speed
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
        do {
            guard let destination = lock.withLock({
                downloadedFileURL
            }) else {
                throw URLError(.cannotCreateFile)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock {
                transferError = error
            }
        }
        _ = session
        _ = downloadTask
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let resumeData = (error as NSError?)?.userInfo[
            NSURLSessionDownloadTaskResumeData
        ] as? Data {
            saveResumeData(resumeData)
        }

        let completion = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            downloadTask = nil
            downloadSession = nil
            let finalError = isCancelled
                ? CancellationError()
                : transferError ?? error
            return (continuation, finalError)
        }
        session.finishTasksAndInvalidate()

        guard let continuation = completion.0 else { return }
        if let error = completion.1 {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    private func saveResumeData(_ data: Data?) {
        guard let data,
              let destination = lock.withLock({
                  resumeDataURL
              }) else {
            return
        }
        try? data.write(to: destination, options: .atomic)
    }
}
