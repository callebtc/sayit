import AppKit
import Observation
import SayItCore
import SayItProtocol
import ServiceManagement

@MainActor
@Observable
final class BackgroundServiceController {
    static let userDisabledDefaultsKey = "backgroundServiceUserDisabled"
    private static let legacyCleanupDefaultsKey =
        "backgroundServiceLegacyCleanupDone"

    private let service = SMAppService.agent(
        plistName: SayItServiceIdentifiers.launchAgentPlist
    )

    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?
    private(set) var isWorking = false
    #if DEBUG || SAYIT_LOCAL_BUILD
    private(set) var isDevelopmentServiceRunning = false
    #endif

    init() {
        status = service.status
    }

    var isEnabled: Bool {
        #if DEBUG || SAYIT_LOCAL_BUILD
        isDevelopmentServiceRunning
        #else
        status == .enabled || status == .requiresApproval
        #endif
    }

    var isUserDisabled: Bool {
        UserDefaults.standard.bool(
            forKey: Self.userDisabledDefaultsKey
        )
    }

    var statusDescription: String {
        if isWorking {
            return "Working…"
        }
        #if DEBUG || SAYIT_LOCAL_BUILD
        return isDevelopmentServiceRunning ? "Running" : "Off"
        #else
        return switch status {
        case .notRegistered:
            "Off"
        case .enabled:
            "Running"
        case .requiresApproval:
            "Approval required"
        case .notFound:
            "Service missing"
        @unknown default:
            "Unknown"
        }
        #endif
    }

    func refresh() {
        let currentStatus = service.status
        if status != currentStatus {
            status = currentStatus
        }
    }

    func ensureRunning() async {
        guard !isUserDisabled else { return }
        await perform {
            await legacyCleanupIfNeeded()
            writeParentProcessFile()
            #if DEBUG || SAYIT_LOCAL_BUILD
            try await ensureDevelopmentServiceRunning()
            #else
            if status == .enabled, parentProcessFileMatches {
                return
            }
            try await restartRegisteredService()
            #endif
        }
    }

    func enable() async {
        UserDefaults.standard.set(
            false,
            forKey: Self.userDisabledDefaultsKey
        )
        await ensureRunning()
    }

    func disable() async {
        await perform {
            #if DEBUG || SAYIT_LOCAL_BUILD
            if DevelopmentServiceLauncher.isLoaded {
                try DevelopmentServiceLauncher.unregister()
            }
            isDevelopmentServiceRunning = false
            #else
            await unregisterAndWait()
            #endif
            removeParentProcessFile()
            UserDefaults.standard.set(
                true,
                forKey: Self.userDisabledDefaultsKey
            )
        }
    }

    func restart() async {
        await perform {
            writeParentProcessFile()
            #if DEBUG || SAYIT_LOCAL_BUILD
            try await ensureDevelopmentServiceRunning()
            #else
            try await restartRegisteredService()
            #endif
        }
    }

    func terminateForQuit() async {
        #if DEBUG || SAYIT_LOCAL_BUILD
        if DevelopmentServiceLauncher.isLoaded {
            try? DevelopmentServiceLauncher.unregister()
        }
        isDevelopmentServiceRunning = false
        #else
        if service.status == .enabled || service.status == .requiresApproval {
            try? await service.unregister()
        }
        #endif
        removeParentProcessFile()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        isWorking = false
    }

    private func legacyCleanupIfNeeded() async {
        #if DEBUG || SAYIT_LOCAL_BUILD
        guard !UserDefaults.standard.bool(
            forKey: Self.legacyCleanupDefaultsKey
        ) else {
            return
        }
        UserDefaults.standard.set(
            true,
            forKey: Self.legacyCleanupDefaultsKey
        )
        DevelopmentServiceLauncher.removeLegacyJobIfNeeded()
        if service.status == .enabled || service.status == .requiresApproval {
            try? await service.unregister()
        }
        refresh()
        #endif
    }

    private func restartRegisteredService() async throws {
        await unregisterAndWait()
        try await registerAndWait()
    }

    private func unregisterAndWait() async {
        guard service.status == .enabled
            || service.status == .requiresApproval else {
            return
        }
        do {
            try await service.unregister()
        } catch {
            errorMessage = error.localizedDescription
        }
        for _ in 0..<50 {
            if service.status == .notRegistered {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        refresh()
    }

    private func registerAndWait() async throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                if service.status != .enabled
                    && service.status != .requiresApproval {
                    try service.register()
                }
                lastError = nil
            } catch {
                lastError = error
            }
            for _ in 0..<50 {
                if service.status == .enabled
                    || service.status == .requiresApproval {
                    refresh()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if attempt == 0 {
                await unregisterAndWait()
            }
        }
        refresh()
        throw lastError ?? ControllerError.registrationFailed
    }

    private var parentProcessFileMatches: Bool {
        guard let directory = serviceDataDirectory,
              let pid = ParentProcessFile.readPID(from: directory) else {
            return false
        }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    private func writeParentProcessFile() {
        guard let directory = serviceDataDirectory else { return }
        ParentProcessFile.write(
            pid: ProcessInfo.processInfo.processIdentifier,
            in: directory
        )
    }

    private func removeParentProcessFile() {
        guard let directory = serviceDataDirectory else { return }
        ParentProcessFile.remove(from: directory)
    }

    private var serviceDataDirectory: URL? {
        try? AppDirectories.shared(
            appGroupIdentifier: SayItServiceIdentifiers.appGroup
        ).applicationSupport
    }

    private enum ControllerError: LocalizedError {
        case registrationFailed

        var errorDescription: String? {
            switch self {
            case .registrationFailed:
                "The background service could not be registered."
            }
        }
    }

    #if DEBUG || SAYIT_LOCAL_BUILD
    private func ensureDevelopmentServiceRunning() async throws {
        try await DevelopmentServiceLauncher.ensureRunning(
            agentURL: agentURL
        )
        isDevelopmentServiceRunning = true
    }

    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: """
            Contents/Library/LaunchServices/\
            SayItAgent.app/Contents/MacOS/SayItAgent
            """
        )
    }
    #endif
}
