import Foundation

public enum ServiceCommand: Codable, Sendable {
    case snapshot
    case events(after: UInt64)
    case submit(SpeechSubmission)
    case jobs
    case confirmJob(UUID)
    case cancelJob(UUID)
    case play
    case pause
    case clear
    case clearError
    case seek(TimeInterval)
    case skip(TimeInterval)
    case setPlaybackRate(Double)
    case models
    case selectModel(String)
    case installModel(String)
    case cancelModelInstall
    case removeModel(String)
    case addCommunityModel(
        repository: String,
        revision: String?,
        accessToken: String?
    )
    case importLocalModel(bookmark: Data)
    case history
    case exportHistory(UUID, format: String)
    case replayHistory(UUID)
    case regenerateHistory(UUID)
    case toggleHistoryPinned(UUID)
    case deleteHistory(UUID)
    case clearHistory
    case diagnostics
    case exportDiagnostics
    case clearDiagnostics
    case updateSettings(BackendSettingsSnapshot)
    case tokens
    case createToken(name: String, scopes: Set<APITokenScope>)
    case revokeToken(UUID)
}
