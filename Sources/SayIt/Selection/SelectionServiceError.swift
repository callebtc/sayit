import Foundation

enum SelectionServiceError: LocalizedError {
    case accessibilityRequired
    case noSelection
    case selectionTooLong(maximumCharacters: Int)
    case frontmostApplicationUnavailable
    case helperRegistrationFailed
    case helperUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            String(localized: "Accessibility access is off. Allow the Say It selected-text helper in Accessibility Settings, then press the shortcut again.")
        case .noSelection:
            String(localized: "No readable text is selected in the frontmost app.")
        case .selectionTooLong(let maximumCharacters):
            String(localized: "The selection is longer than the \(maximumCharacters.formatted()) character safety limit.")
        case .frontmostApplicationUnavailable:
            String(localized: "The frontmost app did not expose a readable text selection.")
        case .helperRegistrationFailed:
            String(localized: "The selected-text helper couldn’t be registered. Install the latest Say It build in Applications, then quit and reopen it.")
        case .helperUnavailable:
            String(localized: "The selected-text helper is unavailable.")
        }
    }

    var recoveryAction: AppErrorRecoveryAction? {
        switch self {
        case .accessibilityRequired:
            .openAccessibilitySettings
        default:
            nil
        }
    }
}
