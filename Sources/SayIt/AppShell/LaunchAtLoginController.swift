import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    var isEnabled: Bool {
        status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        status = SMAppService.mainApp.status
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }
}
