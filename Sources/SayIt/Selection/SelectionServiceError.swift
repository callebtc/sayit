import Foundation

enum SelectionServiceError: LocalizedError {
    case accessibilityRequired
    case noSelection
    case selectionTooLong(maximumCharacters: Int)
    case frontmostApplicationUnavailable
    case helperApprovalRequired
    case helperUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Accessibility access is off. Allow the Say It selected-text helper in Accessibility Settings, then press the shortcut again."
        case .noSelection:
            "No readable text is selected in the frontmost app."
        case .selectionTooLong(let maximumCharacters):
            "The selection is longer than the \(maximumCharacters.formatted()) character safety limit."
        case .frontmostApplicationUnavailable:
            "The frontmost app did not expose a readable text selection."
        case .helperApprovalRequired:
            "Allow the Say It selected-text helper in Login Items."
        case .helperUnavailable:
            "The selected-text helper is unavailable."
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
