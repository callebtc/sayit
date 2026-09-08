import Foundation
import ServiceManagement

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

    static func restart(
        status: () -> SMAppService.Status,
        removeConflict: () async throws -> Void,
        unregister: () async throws -> Void,
        register: () throws -> Void,
        wait: () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async throws {
        try Task.checkCancellation()
        // Respect consent revoked in System Settings; re-registering must not
        // become a way around it, including when a manual job is present.
        guard status() != .requiresApproval else { throw StartupError.approvalRequired }
        try await removeConflict()
        guard status() != .requiresApproval else { throw StartupError.approvalRequired }
        try await unregisterAndWait(status: status, unregister: unregister, wait: wait)
        try Task.checkCancellation()
        try register()
        for _ in 0..<50 {
            try Task.checkCancellation()
            switch status() {
            case .enabled:
                return
            case .requiresApproval:
                throw StartupError.approvalRequired
            default:
                try await wait()
            }
        }
        throw StartupError.registrationTimedOut
    }

    static func unregisterAndWait(
        status: () -> SMAppService.Status,
        unregister: () async throws -> Void,
        wait: () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async throws {
        try Task.checkCancellation()
        guard status() == .enabled || status() == .requiresApproval else { return }
        try await unregister()
        for _ in 0..<50 {
            try Task.checkCancellation()
            if status() == .notRegistered || status() == .notFound { return }
            try await wait()
        }
        throw StartupError.unregistrationTimedOut
    }

    enum StartupError: LocalizedError {
        case approvalRequired, registrationTimedOut, unregistrationTimedOut

        var errorDescription: String? {
            switch self {
            case .approvalRequired:
                "Allow Say It in System Settings → General → Login Items & Extensions to finish starting the service."
            case .registrationTimedOut:
                "The background service could not be registered in time. Try restarting Say It."
            case .unregistrationTimedOut:
                "The older service could not be unregistered in time. Try restarting Say It."
            }
        }
    }
}
