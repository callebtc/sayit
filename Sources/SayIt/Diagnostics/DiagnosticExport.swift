import Foundation
import SayItCore

struct DiagnosticExport: Encodable, Sendable {
    struct SettingsSnapshot: Encodable, Sendable {
        let historyRetention: String
        let historyQuotaBytes: Int64
        let showTitlesInNowPlaying: Bool
        let updateChecksEnabled: Bool
    }

    let generatedAt: Date
    let applicationVersion: String
    let macOSVersion: String
    let architecture: String
    let physicalMemoryBytes: UInt64
    let installedModelIDs: [ModelID]
    let settings: SettingsSnapshot
    let events: [DiagnosticEvent]
}
