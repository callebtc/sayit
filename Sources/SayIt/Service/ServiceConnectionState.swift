import Foundation

enum ServiceConnectionState: Equatable {
    case disabled
    case connecting
    case recovering
    case online(version: String)
    case offline
    case updateRequired

    var label: String {
        switch self {
        case .disabled:
            String(localized: "Disabled")
        case .connecting:
            String(localized: "Connecting")
        case .recovering:
            String(localized: "Reconnecting")
        case .online:
            String(localized: "Connected")
        case .offline:
            String(localized: "Unavailable")
        case .updateRequired:
            String(localized: "Update required")
        }
    }

    var showsRepair: Bool {
        switch self {
        case .disabled, .offline, .updateRequired, .recovering:
            true
        case .connecting, .online:
            false
        }
    }
}
