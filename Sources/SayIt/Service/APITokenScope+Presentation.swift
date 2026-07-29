import SayItProtocol

extension APITokenScope {
    var title: String {
        switch self {
        case .stateRead: "Read state"
        case .speechSubmit: "Submit speech"
        case .playbackControl: "Control playback"
        case .historyRead: "Read history"
        case .historyWrite: "Change history"
        case .modelsRead: "Read models"
        case .modelsWrite: "Change models"
        case .settingsRead: "Read settings"
        case .settingsWrite: "Change settings"
        case .diagnosticsRead: "Read diagnostics"
        case .diagnosticsWrite: "Change diagnostics"
        }
    }
}
