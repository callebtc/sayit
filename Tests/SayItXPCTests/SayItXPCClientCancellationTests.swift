import Foundation
import SayItProtocol
import Testing
@testable import SayItXPC

@Suite("SayItXPCClient task cancellation")
struct SayItXPCClientCancellationTests {
    @Test("Cancelling an in-flight XPC request throws promptly and keeps the client usable")
    func cancelsInFlightRequestWithoutInvalidatingConnection() async throws {
        let delegate = HoldingXPCListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let endpoint = listener.endpoint
        let client = SayItXPCClient {
            NSXPCConnection(listenerEndpoint: endpoint)
        }
        defer {
            Task { await client.invalidate() }
        }

        let hangingTask = Task {
            try await client.send(.events(after: 0))
        }
        await delegate.waitForPendingReply()
        hangingTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await hangingTask.value
        }

        // Resolving the delayed reply after cancellation must not crash, and a
        // subsequent request over the same client must succeed.
        delegate.completePendingReply(with: .accepted)
        delegate.shouldHoldNextRequest = false
        let response = try await client.send(.jobs)
        if case .accepted = response {
            // Expected.
        } else {
            Issue.record("Expected .accepted response after cancellation recovery")
        }
    }

    @Test("Pre-cancelled XPC send throws CancellationError without dispatching")
    func preCancelledSendDoesNotDispatch() async throws {
        let delegate = HoldingXPCListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let endpoint = listener.endpoint
        let client = SayItXPCClient {
            NSXPCConnection(listenerEndpoint: endpoint)
        }
        defer {
            Task { await client.invalidate() }
        }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(.jobs)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(delegate.receivedRequestCount == 0)
    }
}

private final class HoldingXPCListenerDelegate: NSObject, NSXPCListenerDelegate,
    SayItXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingReply: (@Sendable (Data) -> Void)?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var _shouldHoldNextRequest = true
    private var _receivedRequestCount = 0

    var shouldHoldNextRequest: Bool {
        get { lock.withLock { _shouldHoldNextRequest } }
        set { lock.withLock { _shouldHoldNextRequest = newValue } }
    }

    var receivedRequestCount: Int {
        lock.withLock { _receivedRequestCount }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: SayItXPCProtocol.self
        )
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        let hold = lock.withLock { () -> Bool in
            _receivedRequestCount += 1
            if _shouldHoldNextRequest {
                pendingReply = reply
                let waiters = pendingWaiters
                pendingWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                return true
            }
            return false
        }
        guard !hold else { return }
        let encoded = (try? SayItWireCodec.encode(ServiceResponse.accepted)) ?? Data()
        reply(encoded)
    }

    func waitForPendingReply() async {
        await withCheckedContinuation { continuation in
            let alreadyPending = lock.withLock { () -> Bool in
                if pendingReply != nil {
                    return true
                }
                pendingWaiters.append(continuation)
                return false
            }
            if alreadyPending {
                continuation.resume()
            }
        }
    }

    func completePendingReply(with response: ServiceResponse) {
        let reply = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            let current = pendingReply
            pendingReply = nil
            return current
        }
        let encoded = (try? SayItWireCodec.encode(response)) ?? Data()
        reply?(encoded)
    }
}
