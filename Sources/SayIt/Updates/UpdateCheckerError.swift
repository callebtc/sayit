import Foundation

enum UpdateCheckerError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case invalidResponse
    case requestFailed(statusCode: Int)
    case invalidReleaseTag
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            "This build has an invalid version number."
        case .invalidResponse:
            "GitHub returned an invalid update response."
        case .requestFailed:
            "GitHub couldn’t complete the update check."
        case .invalidReleaseTag:
            "The latest GitHub release has an invalid version tag."
        case .invalidReleaseURL:
            "The latest GitHub release has an invalid web address."
        }
    }
}
