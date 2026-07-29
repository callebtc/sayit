import Foundation

public enum APITokenPreset: String, Codable, CaseIterable, Sendable {
    case readOnly
    case speechControl
    case fullAccess

    public var scopes: Set<APITokenScope> {
        switch self {
        case .readOnly:
            [.stateRead, .historyRead, .modelsRead, .settingsRead, .diagnosticsRead]
        case .speechControl:
            [.stateRead, .speechSubmit, .playbackControl, .historyRead, .modelsRead]
        case .fullAccess:
            Set(APITokenScope.allCases)
        }
    }
}
