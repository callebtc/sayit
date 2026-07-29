import Foundation

public enum RetentionPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case forever

    public var id: String { rawValue }

    public var interval: TimeInterval? {
        switch self {
        case .sevenDays:
            7 * 24 * 60 * 60
        case .thirtyDays:
            30 * 24 * 60 * 60
        case .ninetyDays:
            90 * 24 * 60 * 60
        case .forever:
            nil
        }
    }
}
