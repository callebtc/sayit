import Foundation

enum ServiceConnectionState: Equatable {
    case disabled
    case connecting
    case online(version: String)
    case offline
    case updateRequired

    var label: String {
        switch self {
        case .disabled:
            "Disabled"
        case .connecting:
            "Connecting"
        case .online:
            "Connected"
        case .offline:
            "Unavailable"
        case .updateRequired:
            "Update required"
        }
    }

    var showsRepair: Bool {
        switch self {
        case .disabled, .offline, .updateRequired:
            true
        case .connecting, .online:
            false
        }
    }
}
