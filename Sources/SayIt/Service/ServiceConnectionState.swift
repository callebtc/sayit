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
            "Disabled"
        case .connecting:
            "Connecting"
        case .recovering:
            "Reconnecting"
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
        case .disabled, .offline, .updateRequired, .recovering:
            true
        case .connecting, .online:
            false
        }
    }
}
