import AppKit
import Observation
import SayItCore
import SayItProtocol
import SayItXPC
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
    private var hasStartedService = false
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

    var requiresApproval: Bool {
        #if DEBUG || SAYIT_LOCAL_BUILD
        false
        #else
        status == .requiresApproval
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
            "Registered"
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
            #if DEBUG || SAYIT_LOCAL_BUILD
            writeParentProcessFile()
            try await ensureDevelopmentServiceRunning()
            #else
            try await RegisteredServiceStartup.ensureRunning(
                isEnabled: hasStartedService && service.status == .enabled,
                parentProcessMatches: { parentProcessFileMatches },
                writeParentProcess: { writeParentProcessFile() },
                restart: { try await restartRegisteredService() }
            )
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
        // Preserve the user's intent even if stopping the system job fails.
        UserDefaults.standard.set(true, forKey: Self.userDisabledDefaultsKey)
        hasStartedService = false
        await perform {
            #if DEBUG || SAYIT_LOCAL_BUILD
            if DevelopmentServiceLauncher.isLoaded {
                try DevelopmentServiceLauncher.unregister()
            }
            isDevelopmentServiceRunning = false
            #else
            try await unregisterAndWait()
            #endif
            removeParentProcessFile()
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
            hasStartedService = !isUserDisabled
        } catch {
            hasStartedService = false
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
        try await RegisteredServiceStartup.restart(
            status: { service.status },
            removeConflict: {
                try await LegacyServiceJobRecovery.removeConflict(
                    label: URL(filePath: SayItServiceIdentifiers.launchAgentPlist)
                        .deletingPathExtension().lastPathComponent,
                    machServiceName: SayItServiceIdentifiers.machService,
                    agentURL: agentURL,
                    bundledPlistURL: Bundle.main.bundleURL.appending(
                        path: "Contents/Library/LaunchAgents/\(SayItServiceIdentifiers.launchAgentPlist)"
                    )
                )
            },
            unregister: { try await service.unregister() },
            register: { try service.register() }
        )
    }

    private func unregisterAndWait() async throws {
        try await RegisteredServiceStartup.unregisterAndWait(
            status: { service.status },
            unregister: { try await service.unregister() }
        )
        refresh()
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

    #if DEBUG || SAYIT_LOCAL_BUILD
    private func ensureDevelopmentServiceRunning() async throws {
        try await DevelopmentServiceLauncher.ensureRunning(
            agentURL: agentURL
        )
        isDevelopmentServiceRunning = true
    }

    #endif

    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: """
            Contents/Library/LaunchServices/\
            SayItAgent.app/Contents/MacOS/SayItAgent
            """
        )
    }
}
