import Foundation
import SayItProtocol
import Synchronization
import Testing
@testable import SayItXPC

@Suite("XPC request lifetime", .timeLimit(.minutes(1)))
struct SayItXPCClientTests {
    @Test("Both send overloads preserve wire requests and service failures")
    func forwardsRequestsAndResponses() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let request = ServiceRequest(protocolVersion: 73, command: .seek(12.5))
        let task = Task { try await client.send(request) }
        let invocation = try #require(await requests.next())
        #expect(invocation.data == (try SayItWireCodec.encode(request)))
        try await invocation.respond(.failure(ServiceFailure(code: "busy", message: "Try later")))
        if case .failure(let failure) = try await task.value {
            #expect(failure.code == "busy")
            #expect(failure.message == "Try later")
        } else {
            Issue.record("Expected the service failure response")
        }

        let commandTask = Task { try await client.send(.pause) }
        let commandInvocation = try #require(await requests.next())
        let decoded = try SayItWireCodec.decode(ServiceRequest.self, from: commandInvocation.data)
        #expect(decoded.protocolVersion == SayItProtocolVersion.current)
        if case .pause = decoded.command {} else { Issue.record("Expected pause") }
        try await commandInvocation.respond()
        expectAccepted(try await commandTask.value)
        #expect(connection.activations == 1)
        #expect(connection.sends == 2)
    }

    @Test("Encoding failure creates no connection and a later valid command still succeeds")
    func encodingFailure() async throws {
        let connection = ScriptedXPCConnection()
        let creations = Mutex(0)
        let client = SayItXPCClient(connectionFactory: {
            creations.withLock { $0 += 1 }
            return connection
        })
        await #expect(throws: EncodingError.self) {
            try await client.send(.setVolume(.infinity))
        }
        #expect(creations.withLock { $0 } == 0)
        #expect(connection.sends == 0)

        var requests = connection.requests.makeAsyncIterator()
        let task = Task { try await client.send(.pause) }
        let invocation = try #require(await requests.next())
        try await invocation.respond()
        expectAccepted(try await task.value)
    }

    @Test("Invalid responses finish only their request and duplicate callbacks are ignored")
    func decodingFailureAndDuplicateCallbacks() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let invalid = Task { try await client.send(.pause) }
        let invalidInvocation = try #require(await requests.next())
        let sibling = Task { try await client.send(.play) }
        let siblingInvocation = try #require(await requests.next())

        await invalidInvocation.reply(.success(Data("invalid JSON".utf8)))
        do {
            _ = try await invalid.value
            Issue.record("Expected invalidResponse")
        } catch {
            if case .invalidResponse = error as? SayItXPCClientError {} else {
                Issue.record("Expected invalidResponse, received \(error)")
            }
        }
        try await invalidInvocation.respond()
        await invalidInvocation.reply(.failure(.requestFailed("duplicate error")))
        #expect(connection.invalidations == 0)
        try await siblingInvocation.respond()
        expectAccepted(try await sibling.value)
        try await siblingInvocation.respond()
        await siblingInvocation.reply(.success(Data()))
        await siblingInvocation.reply(.failure(.connectionUnavailable))
        #expect(connection.invalidations == 0)
    }

    @Test("Cancellation while awaiting a reply finishes without affecting a sibling")
    func cancellationDuringPendingReply() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        // Reusing a wire identifier must not merge two local request lifetimes.
        let request = ServiceRequest(command: .pause)
        let canceled = Task { try await client.send(request) }
        let canceledInvocation = try #require(await requests.next())
        let sibling = Task { try await client.send(request) }
        let siblingInvocation = try #require(await requests.next())

        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(connection.invalidations == 0)
        try await canceledInvocation.respond()
        await canceledInvocation.reply(.failure(.requestFailed("late canceled error")))
        try await siblingInvocation.respond()
        expectAccepted(try await sibling.value)
        #expect(connection.sends == 2)
        #expect(connection.activations == 1)
        #expect(connection.invalidations == 0)
    }

    @Test("Explicit invalidation drains every pending request before any reply")
    func invalidationDrainsMultipleRequests() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let first = Task { try await client.send(.pause) }
        let firstInvocation = try #require(await requests.next())
        let second = Task { try await client.send(.play) }
        let secondInvocation = try #require(await requests.next())

        await client.invalidate()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        await client.invalidate()
        #expect(connection.invalidations == 1)
        try await firstInvocation.respond()
        await secondInvocation.reply(.failure(.connectionUnavailable))
        await connection.fail(.requestFailed("invalidated"))
        #expect(connection.sends == 2)
    }

    @Test("Transport failure drains siblings and never replays commands")
    func transportFailureDrainsSiblings() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let first = Task { try await client.send(.pause) }
        let firstInvocation = try #require(await requests.next())
        let second = Task { try await client.send(.play) }
        let secondInvocation = try #require(await requests.next())

        await firstInvocation.reply(.failure(.requestFailed("transport failed")))
        await expectRequestFailure(first, message: "transport failed")
        await expectRequestFailure(second, message: "transport failed")
        try await firstInvocation.respond()
        try await secondInvocation.respond()
        #expect(connection.invalidations == 1)
        #expect(connection.sends == 2)
    }

    @Test("A missing proxy finishes with connectionUnavailable")
    func proxyUnavailable() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let task = Task { try await client.send(.pause) }
        let invocation = try #require(await requests.next())
        await invocation.reply(.failure(.connectionUnavailable))
        do {
            _ = try await task.value
            Issue.record("Expected connectionUnavailable")
        } catch {
            if case .connectionUnavailable = error as? SayItXPCClientError {} else {
                Issue.record("Expected connectionUnavailable, received \(error)")
            }
        }
        #expect(connection.invalidations == 1)
    }

    @Test("Connection interruption or invalidation drains pending work", arguments: ["interrupted", "invalidated"])
    func connectionFailure(_ message: String) async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let first = Task { try await client.send(.pause) }
        let firstInvocation = try #require(await requests.next())
        let second = Task { try await client.send(.play) }
        let secondInvocation = try #require(await requests.next())
        await connection.fail(.requestFailed(message))
        await expectRequestFailure(first, message: message)
        await expectRequestFailure(second, message: message)
        await connection.fail(.requestFailed("duplicate event"))
        try await firstInvocation.respond()
        try await secondInvocation.respond()
        #expect(connection.invalidations == 1)
        #expect(connection.sends == 2)
    }

    @Test("Old callbacks cannot retire a replacement or finish its requests", arguments: [false, true])
    func oldConnectionCallbacks(_ explicitInvalidation: Bool) async throws {
        let old = ScriptedXPCConnection()
        let replacement = ScriptedXPCConnection()
        let creations = Mutex(0)
        let client = SayItXPCClient(connectionFactory: {
            creations.withLock {
                $0 += 1
                return $0 == 1 ? old : replacement
            }
        })
        var oldRequests = old.requests.makeAsyncIterator()
        var newRequests = replacement.requests.makeAsyncIterator()
        let request = ServiceRequest(command: .pause)
        let first = Task { try await client.send(request) }
        let oldInvocation = try #require(await oldRequests.next())
        if explicitInvalidation {
            await client.invalidate()
            await #expect(throws: CancellationError.self) { try await first.value }
        } else {
            await old.fail(.requestFailed("old connection failed"))
            await expectRequestFailure(first, message: "old connection failed")
        }

        let second = Task { try await client.send(request) }
        let secondInvocation = try #require(await newRequests.next())
        try await secondInvocation.respond()
        expectAccepted(try await second.value)
        let third = Task { try await client.send(.play) }
        let thirdInvocation = try #require(await newRequests.next())

        await oldInvocation.reply(.failure(.requestFailed("late old proxy error")))
        await old.fail(.requestFailed("late old interruption"))
        await old.fail(.requestFailed("late old invalidation"))
        try await oldInvocation.respond()
        await oldInvocation.reply(.success(Data()))
        #expect(replacement.invalidations == 0)
        try await thirdInvocation.respond()
        expectAccepted(try await third.value)
        #expect(creations.withLock { $0 } == 2)
        #expect(old.sends == 1)
        #expect(old.invalidations == 1)
        #expect(replacement.activations == 1)
        #expect(replacement.sends == 2)
    }

    @Test("Proxy errors retain the transport failure and retire the connection")
    func proxyFailure() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let task = Task { try await client.send(.pause) }
        let invocation = try #require(await requests.next())

        await invocation.reply(.failure(.requestFailed("proxy failed")))

        do {
            _ = try await task.value
            Issue.record("Expected the proxy failure")
        } catch {
            #expect(error is SayItXPCClientError)
            #expect(error.localizedDescription == "proxy failed")
        }
        #expect(connection.invalidations == 1)
    }

    @Test("Cancellation during creation or activation prevents dispatch", arguments: [false, true])
    func cancellationBeforeDispatch(_ cancelDuringCreation: Bool) async throws {
        let connection = ScriptedXPCConnection(onActivate: {
            if !cancelDuringCreation {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let client = SayItXPCClient(connectionFactory: {
            if cancelDuringCreation {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return connection
        })
        let responder = Task {
            var requests = connection.requests.makeAsyncIterator()
            if let invocation = await requests.next() {
                try await invocation.respond()
            }
        }
        let task = Task { try await client.send(.pause) }

        await #expect(throws: CancellationError.self) { try await task.value }
        responder.cancel()
        try await responder.value
        #expect(connection.sends == 0)
        #expect(connection.invalidations == 0)
    }

    @Test("Cancellation before registration sends nothing")
    func cancellationBeforeRegistration() async {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(.setVolume(.infinity))
        }
        // Cancellation must win even before encoding (infinity cannot be encoded).
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connection.sends == 0)
    }

    @Test("Explicit invalidation wins over a late reply")
    func invalidationFinishesPendingRequest() async throws {
        let connection = ScriptedXPCConnection()
        let client = SayItXPCClient(connectionFactory: { connection })
        var requests = connection.requests.makeAsyncIterator()
        let task = Task { try await client.send(.pause) }
        let invocation = try #require(await requests.next())

        await client.invalidate()
        try await invocation.respond()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connection.sends == 1)
    }

    private func expectAccepted(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) {
        if case .accepted = response {} else {
            Issue.record("Expected accepted, received \(response)", sourceLocation: sourceLocation)
        }
    }

    private func expectRequestFailure(
        _ task: Task<ServiceResponse, any Error>,
        message: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected requestFailed", sourceLocation: sourceLocation)
        } catch {
            if case .requestFailed(let actual) = error as? SayItXPCClientError {
                #expect(actual == message, sourceLocation: sourceLocation)
            } else {
                Issue.record("Expected requestFailed, received \(error)", sourceLocation: sourceLocation)
            }
        }
    }
}
