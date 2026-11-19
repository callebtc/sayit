import Foundation
import Synchronization

/// Watches one API token until it is revoked.
///
/// Each open HTTP event stream holds its own watch. Revocation ends every
/// watch for that token. Cancelling one wait, between streamed reads, leaves
/// the watch able to wait again.
public final class APITokenRevocationWatch: Sendable {
    private struct State {
        var revoked = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    let id: UUID
    private let tokenID: UUID
    private let registry: APITokenRevocationRegistry
    private let state = Mutex(State())

    init(
        id: UUID,
        tokenID: UUID,
        registry: APITokenRevocationRegistry
    ) {
        self.id = id
        self.tokenID = tokenID
        self.registry = registry
    }

    public var isRevoked: Bool {
        state.withLock { $0.revoked }
    }

    func revoke() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.revoked = true
            return takeContinuation(&state)
        }
        continuation?.resume()
    }

    public func waitUntilRevoked() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.revoked || Task.isCancelled {
                        return true
                    }
                    state.continuation = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                takeContinuation(&state)
            }
            continuation?.resume()
        }
    }

    public func finish() async {
        let continuation = state.withLock { state in
            takeContinuation(&state)
        }
        continuation?.resume()
        await registry.finish(tokenID: tokenID, watchID: id)
    }

    private func takeContinuation(
        _ state: inout State
    ) -> CheckedContinuation<Void, Never>? {
        let continuation = state.continuation
        state.continuation = nil
        return continuation
    }
}

actor APITokenRevocationRegistry {
    private var watchesByToken: [UUID: [UUID: APITokenRevocationWatch]] = [:]

    func watch(_ tokenID: UUID) -> APITokenRevocationWatch {
        let watch = APITokenRevocationWatch(
            id: UUID(),
            tokenID: tokenID,
            registry: self
        )
        watchesByToken[tokenID, default: [:]][watch.id] = watch
        return watch
    }

    func revoke(_ tokenID: UUID) {
        let open = watchesByToken.removeValue(forKey: tokenID) ?? [:]
        for watch in open.values {
            watch.revoke()
        }
    }

    func finish(tokenID: UUID, watchID: UUID) {
        watchesByToken[tokenID]?.removeValue(forKey: watchID)
        if watchesByToken[tokenID]?.isEmpty == true {
            watchesByToken.removeValue(forKey: tokenID)
        }
    }
}
