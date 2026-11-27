import Foundation

enum AppErrorRecoveryAction: Equatable {
    case openAccessibilitySettings

    var buttonTitle: String {
        switch self {
        case .openAccessibilitySettings:
            String(localized: "Open Accessibility Settings…")
        }
    }
}
