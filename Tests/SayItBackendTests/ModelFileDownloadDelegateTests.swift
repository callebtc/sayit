import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Model file downloads", .serialized)
struct ModelFileDownloadDelegateTests {
    @Test("Downloads replace destinations and report cumulative progress")
    func successfulDownloadAndProgress() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItDownloadTests"
        )
        defer { fixture.remove() }
        let body = Data("model bytes".utf8)
        let session = makeDownloadSession { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "about:blank")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(body.count)"]
                )!,
                body
            )
        }
        defer { session.invalidateAndCancel() }
        let recorder = DownloadProgressRecorder()
        let destination = fixture.root.appending(path: "model.bin")
        let resumeURL = fixture.root.appending(path: "model.resume")
        try Data("old".utf8).write(to: destination)
        let delegate = ModelFileDownloadDelegate(
            modelID: ModelID("download-test"),
            baseCompletedBytes: 100,
            totalModelBytes: 1_000
        ) { progress in
            await recorder.append(progress)
        }
        let request = URLRequest(
            url: URL(string: "https://download.invalid/model.bin")!
        )

        let response = try await delegate.download(
            using: session,
            request: request,
            resumeData: nil,
            to: destination,
            resumeDataURL: resumeURL
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: destination) == body)

        let task = session.downloadTask(with: request)
        try await Task.sleep(for: .milliseconds(110))
        delegate.urlSession(
            session,
            downloadTask: task,
            didWriteData: 5,
            totalBytesWritten: 5,
            totalBytesExpectedToWrite: 10
        )
        delegate.urlSession(
            session,
            downloadTask: task,
            didWriteData: 1,
            totalBytesWritten: 6,
            totalBytesExpectedToWrite: 10
        )
        try await waitForDownloadProgress(recorder)
        let updates = await recorder.values
        #expect(updates.first?.modelID == ModelID("download-test"))
        #expect(updates.contains { $0.completedBytes >= 100 })
        #expect(updates.first?.totalBytes == 1_000)
        #expect(updates.first?.state == .downloading)
    }

    @Test("Transport and destination failures are surfaced")
    func transferFailures() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItDownloadTests"
        )
        defer { fixture.remove() }
        let request = URLRequest(
            url: URL(string: "https://download.invalid/model.bin")!
        )

        let failingSession = makeDownloadSession { _ in
            throw URLError(.timedOut)
        }
        defer { failingSession.invalidateAndCancel() }
        let failingDelegate = makeDownloadDelegate()
        await #expect(throws: URLError.self) {
            _ = try await failingDelegate.download(
                using: failingSession,
                request: request,
                resumeData: nil,
                to: fixture.root.appending(path: "failed.bin"),
                resumeDataURL: fixture.root.appending(path: "failed.resume")
            )
        }

        let successfulSession = makeDownloadSession { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "about:blank")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data([1, 2, 3])
            )
        }
        defer { successfulSession.invalidateAndCancel() }
        let impossibleDestination = fixture.root
            .appending(path: "missing", directoryHint: .isDirectory)
            .appending(path: "model.bin")
        await #expect(throws: (any Error).self) {
            _ = try await makeDownloadDelegate().download(
                using: successfulSession,
                request: request,
                resumeData: nil,
                to: impossibleDestination,
                resumeDataURL: fixture.root.appending(path: "move.resume")
            )
        }
    }

    @Test("Cancellation terminates an in-flight transfer")
    func cancellation() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItDownloadTests"
        )
        defer { fixture.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(
            url: URL(string: "https://download.invalid/hanging.bin")!
        )
        let delegate = makeDownloadDelegate()

        let transfer = Task {
            try await delegate.download(
                using: session,
                request: request,
                resumeData: nil,
                to: fixture.root.appending(path: "hanging.bin"),
                resumeDataURL: fixture.root.appending(path: "hanging.resume")
            )
        }
        await Task.yield()
        transfer.cancel()
        do {
            _ = try await transfer.value
            Issue.record("Expected download cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("Resume data takes the resumed-task path")
    func invalidResumeData() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItDownloadTests"
        )
        defer { fixture.remove() }
        let session = makeDownloadSession { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "about:blank")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data([1])
            )
        }
        defer { session.invalidateAndCancel() }
        let destination = fixture.root.appending(path: "resumed.bin")

        let response = try await makeDownloadDelegate().download(
            using: session,
            request: URLRequest(
                url: URL(string: "https://download.invalid/resumed.bin")!
            ),
            resumeData: Data("not resume data".utf8),
            to: destination,
            resumeDataURL: fixture.root.appending(path: "resumed.resume")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: destination) == Data([1]))
    }
}

private func makeDownloadDelegate() -> ModelFileDownloadDelegate {
    ModelFileDownloadDelegate(
        modelID: ModelID("download-test"),
        baseCompletedBytes: 0,
        totalModelBytes: 10
    ) { _ in }
}

private func makeDownloadSession(
    handler:
        @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    DownloadStubURLProtocol.setHandler(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func waitForDownloadProgress(
    _ recorder: DownloadProgressRecorder
) async throws {
    for _ in 0..<100 {
        if await !recorder.values.isEmpty {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("No download progress was reported")
}

private actor DownloadProgressRecorder {
    private(set) var values: [ModelDownloadProgress] = []

    func append(_ value: ModelDownloadProgress) {
        values.append(value)
    }
}

private final class DownloadStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(
        _ newHandler:
            @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            handler = newHandler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            guard let handler else {
                throw URLError(.unknown)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HangingDownloadURLProtocol: URLProtocol,
    @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {}
    override func stopLoading() {}
}
