import Foundation

public enum APITokenScope: String, Codable, CaseIterable, Sendable {
    case stateRead = "state:read"
    case speechSubmit = "speech:submit"
    case playbackControl = "playback:control"
    case historyRead = "history:read"
    case historyWrite = "history:write"
    case modelsRead = "models:read"
    case modelsWrite = "models:write"
    case voicesRead = "voices:read"
    case voicesWrite = "voices:write"
    case settingsRead = "settings:read"
    case settingsWrite = "settings:write"
    case diagnosticsRead = "diagnostics:read"
    case diagnosticsWrite = "diagnostics:write"
}
