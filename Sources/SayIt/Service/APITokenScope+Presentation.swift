import Foundation
import SayItProtocol

extension APITokenScope {
    var title: String {
        switch self {
        case .stateRead: String(localized: "Read state")
        case .speechSubmit: String(localized: "Submit speech")
        case .playbackControl: String(localized: "Control playback")
        case .historyRead: String(localized: "Read history")
        case .historyWrite: String(localized: "Change history")
        case .modelsRead: String(localized: "Read models")
        case .modelsWrite: String(localized: "Change models")
        case .voicesRead: String(localized: "Read voices")
        case .voicesWrite: String(localized: "Change voices")
        case .settingsRead: String(localized: "Read settings")
        case .settingsWrite: String(localized: "Change settings")
        case .diagnosticsRead: String(localized: "Read diagnostics")
        case .diagnosticsWrite: String(localized: "Change diagnostics")
        }
    }
}
