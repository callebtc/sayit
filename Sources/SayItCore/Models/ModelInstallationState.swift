import Foundation

public enum ModelInstallationState: String, Codable, Sendable {
    case notInstalled
    case queued
    case downloading
    case canceling
    case paused
    case verifying
    case installed
    case failed
}
