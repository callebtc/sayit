import Foundation

enum UpdatePhase: Equatable {
    case idle
    case checking
    case available
    case downloading
    case extracting
    case preparing
    case installing
    case current
    case failed
    case unavailable

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .preparing, .installing: true
        default: false
        }
    }
}
