import AppKit
import Observation
import SayItProtocol
import ServiceManagement

@MainActor
@Observable
final class BackgroundServiceController {
    static let userDisabledDefaultsKey = "backgroundServiceUserDisabled"

    private let service = SMAppService.agent(
        plistName: SayItServiceIdentifiers.launchAgentPlist
    )

    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?
#if DEBUG
    private(set) var isDevelopmentServiceRunning = false
#endif

    init() {
        status = service.status
    }

    var isEnabled: Bool {
#if DEBUG
        status == .enabled
            || status == .requiresApproval
            || isDevelopmentServiceRunning
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
#if DEBUG
        if isDevelopmentServiceRunning {
            return "Running"
        }
#endif
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
    }

    func refresh() {
        status = service.status
    }

    func enable() async {
        errorMessage = nil
        UserDefaults.standard.set(
            false,
            forKey: Self.userDisabledDefaultsKey
        )
        var registrationError: Error?
        do {
            if service.status != .enabled
                && service.status != .requiresApproval {
                try service.register()
            }
        } catch {
            registrationError = error
        }
        refresh()

#if DEBUG
        do {
            try await DevelopmentServiceLauncher.ensureRunning(
                agentURL: agentURL
            )
            isDevelopmentServiceRunning = true
            registrationError = nil
        } catch {
            isDevelopmentServiceRunning = false
            if status != .enabled && status != .requiresApproval {
                registrationError = error
            }
        }
#endif
        errorMessage = registrationError?.localizedDescription
    }

    func disable() async {
        errorMessage = nil
#if DEBUG
        if isDevelopmentServiceRunning {
            do {
                try DevelopmentServiceLauncher.unregister()
                isDevelopmentServiceRunning = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
#endif
        do {
            if service.status == .enabled
                || service.status == .requiresApproval {
                try await service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        UserDefaults.standard.set(
            true,
            forKey: Self.userDisabledDefaultsKey
        )
        refresh()
    }

    func restart() async {
        errorMessage = nil
#if DEBUG
        if isDevelopmentServiceRunning {
            do {
                try DevelopmentServiceLauncher.unregister()
                try await DevelopmentServiceLauncher.ensureRunning(
                    agentURL: agentURL
                )
            } catch {
                isDevelopmentServiceRunning = false
                errorMessage = error.localizedDescription
            }
            return
        }
#endif
        do {
            if service.status == .enabled
                || service.status == .requiresApproval {
                try await service.unregister()
            }
            try service.register()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

#if DEBUG
    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Library/LaunchServices/SayItAgent"
        )
    }
#endif
}
