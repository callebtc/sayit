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

    init() {
        status = service.status
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var statusDescription: String {
        switch status {
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

    func enable() {
        errorMessage = nil
        UserDefaults.standard.set(
            false,
            forKey: Self.userDisabledDefaultsKey
        )
        do {
            if service.status == .notRegistered {
                try service.register()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func disable() async {
        errorMessage = nil
        do {
            if service.status != .notRegistered {
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
        do {
            if service.status != .notRegistered {
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
}
