import Foundation
import SayItCore

extension ModelExperience.Size {
    var localizedDisplayName: String {
        switch self {
        case .small:
            String(localized: "Small")
        case .medium:
            String(localized: "Medium")
        case .large:
            String(localized: "Large")
        }
    }
}

extension ModelExperience.Speed {
    var localizedDisplayName: String {
        switch self {
        case .fast:
            String(localized: "Fast")
        case .mediumFast:
            String(localized: "Medium-fast")
        case .medium:
            String(localized: "Medium")
        case .mediumSlow:
            String(localized: "Medium-slow")
        case .slow:
            String(localized: "Slow")
        }
    }
}

extension ModelExperience {
    var localizedNote: String? {
        guard let note else { return nil }
        return Bundle.main.localizedString(forKey: note, value: note, table: nil)
    }
}
