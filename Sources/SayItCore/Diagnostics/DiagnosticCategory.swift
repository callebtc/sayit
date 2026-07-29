import Foundation

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case lifecycle
    case ingestion
    case model
    case download
    case synthesis
    case playback
    case history
    case update
}
