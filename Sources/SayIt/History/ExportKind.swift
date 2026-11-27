import Foundation

enum ExportKind: String, CaseIterable, Identifiable {
    case m4a
    case wav
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4a: String(localized: "M4A Audio")
        case .wav: String(localized: "WAV Audio")
        case .text: String(localized: "Text")
        }
    }
}
