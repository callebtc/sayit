import Foundation

enum ExportKind: String, CaseIterable, Identifiable {
    case m4a
    case wav
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4a: "M4A Audio"
        case .wav: "WAV Audio"
        case .text: "Text"
        }
    }
}
