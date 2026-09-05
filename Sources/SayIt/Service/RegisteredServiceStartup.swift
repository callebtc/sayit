@MainActor
enum RegisteredServiceStartup {
    static func ensureRunning(
        isEnabled: Bool,
        parentProcessMatches: () -> Bool,
        writeParentProcess: () -> Void,
        restart: () async throws -> Void
    ) async throws {
        // Read ownership before publishing this process as the new owner.
        // Otherwise an agent left by another app version looks reusable.
        let canReuseService = isEnabled && parentProcessMatches()
        writeParentProcess()
        if !canReuseService {
            try await restart()
        }
    }
}
