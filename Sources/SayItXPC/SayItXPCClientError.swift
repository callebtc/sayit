import Foundation

public enum SayItXPCClientError: LocalizedError, Sendable {
    case connectionUnavailable
    case invalidResponse
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            "The Say It background service is unavailable."
        case .invalidResponse:
            "The Say It background service returned an invalid response."
        case .requestFailed(let message):
            message
        }
    }
}
