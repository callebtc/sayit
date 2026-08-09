import SayItCore
import SayItProtocol

@MainActor
enum SelectionRequestFlow {
    static func perform(
        readSelection: () async throws -> TextSourcePayload,
        requestAuthorization: () async throws -> Bool,
        resumeTargetApplication: () async throws -> Void
    ) async throws -> TextSourcePayload {
        do {
            return try await readSelection()
        } catch SelectionServiceError.accessibilityRequired {
            guard try await requestAuthorization() else {
                throw SelectionServiceError.accessibilityRequired
            }
            try await resumeTargetApplication()
            return try await readSelection()
        }
    }
}
