import Foundation

import SayItCore

enum ModelManagerError: LocalizedError {
    case modelNotFound
    case modelUnavailable
    case anotherDownloadIsActive
    case insufficientDiskSpace(required: Int64)
    case invalidDownloadURL
    case invalidResponse
    case checksumMismatch(path: String)
    case incompleteSnapshot
    case activeModelCannotBeRemoved

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            "The model is not in the Say It catalog."
        case .modelUnavailable:
            "This model requires voice profiles, which are not available yet."
        case .anotherDownloadIsActive:
            "Another model download is already active."
        case .insufficientDiskSpace(let required):
            "The model needs at least \(required.formatted(.byteCount(style: .file))) free."
        case .invalidDownloadURL:
            "The model repository returned an invalid download address."
        case .invalidResponse:
            "The model repository returned an invalid response."
        case .checksumMismatch:
            "A downloaded model file failed its integrity check."
        case .incompleteSnapshot:
            "The model snapshot is incomplete."
        case .activeModelCannotBeRemoved:
            "Choose a different model before deleting the active model."
        }
    }
}
