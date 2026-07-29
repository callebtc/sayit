import Foundation

public protocol TextIngesting: Sendable {
    func ingest(_ payload: TextSourcePayload) async throws -> CleanedText
}
