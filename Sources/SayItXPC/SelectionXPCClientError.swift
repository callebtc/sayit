import Foundation

public enum SelectionXPCClientError: LocalizedError, Sendable {
    case connectionUnavailable
    case invalidResponse
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            "The selected-text helper is unavailable."
        case .invalidResponse:
            "The selected-text helper returned an invalid response."
        case .requestFailed(let message):
            message
        }
    }
}
