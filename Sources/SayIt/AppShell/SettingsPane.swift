import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case speech
    case models
    case history
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
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
        case .speech: "waveform"
        case .models: "internaldrive"
        case .history: "clock.arrow.circlepath"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}
