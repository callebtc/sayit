import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case service
    case speech
    case models
    case history
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .service: "Service"
        case .speech: "Speech"
        case .models: "Models"
        case .history: "History"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .service: "server.rack"
        case .speech: "waveform"
        case .models: "internaldrive"
        case .history: "clock.arrow.circlepath"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}
