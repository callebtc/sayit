import Foundation
import SayItProtocol
import Synchronization
@testable import SayItXPC

final class ScriptedXPCConnection: SayItXPCConnection, Sendable {
    struct Invocation: Sendable {
        let data: Data
        let reply: @Sendable (Result<Data, SayItXPCClientError>) async -> Void

        func respond(_ response: ServiceResponse = .accepted) async throws {
            await reply(.success(try SayItWireCodec.encode(response)))
        }
    }

    private struct State {
        var failure: (@Sendable (SayItXPCClientError) async -> Void)?
        var invalidations = 0
        var activations = 0
        var sends = 0
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<Invocation>.Continuation
    let requests: AsyncStream<Invocation>
    let onActivate: @Sendable () -> Void

    init(onActivate: @escaping @Sendable () -> Void = {}) {
        (requests, continuation) = AsyncStream.makeStream()
        self.onActivate = onActivate
    }

    var invalidations: Int { state.withLock { $0.invalidations } }
    var sends: Int { state.withLock { $0.sends } }
    var activations: Int { state.withLock { $0.activations } }

    func activate(onFailure: @escaping @Sendable (SayItXPCClientError) async -> Void) {
        state.withLock {
            $0.failure = onFailure
            $0.activations += 1
        }
        onActivate()
    }

    func send(
        _ request: Data,
        reply: @escaping @Sendable (Result<Data, SayItXPCClientError>) async -> Void
    ) {
        state.withLock { $0.sends += 1 }
        continuation.yield(Invocation(data: request, reply: reply))
    }

    func fail(_ error: SayItXPCClientError) async {
        let failure = state.withLock { $0.failure }
        await failure?(error)
    }

    func invalidate() {
        state.withLock { $0.invalidations += 1 }
    }
}
