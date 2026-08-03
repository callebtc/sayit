enum AppErrorRecoveryAction: Equatable {
    case openAccessibilitySettings

    var buttonTitle: String {
        switch self {
        case .openAccessibilitySettings:
            "Open Accessibility Settings…"
        }
    }
}
