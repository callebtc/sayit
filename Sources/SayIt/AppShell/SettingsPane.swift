import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case service
    case speech
    case voices
    case models
    case history
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .service: String(localized: "Service")
        case .speech: String(localized: "Speech")
        case .voices: String(localized: "Voices")
        case .models: String(localized: "Models")
        case .history: String(localized: "History")
        case .diagnostics: String(localized: "Diagnostics")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .service: "server.rack"
        case .speech: "waveform"
        case .voices: "person.wave.2"
        case .models: "internaldrive"
        case .history: "clock.arrow.circlepath"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}
