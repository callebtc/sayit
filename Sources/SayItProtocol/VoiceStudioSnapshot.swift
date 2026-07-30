import Foundation

public enum VoiceStudioState: String, Codable, Sendable {
    case generating
    case ready
    case failed
}

public struct VoiceStudioSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let modelID: String
    public let state: VoiceStudioState
    public let completedCount: Int
    public let totalCount: Int
    public let candidates: [VoiceCandidateSnapshot]
    public let errorMessage: String?

    public init(
        id: UUID,
        modelID: String,
        state: VoiceStudioState,
        completedCount: Int,
        totalCount: Int,
        candidates: [VoiceCandidateSnapshot],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.modelID = modelID
        self.state = state
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.candidates = candidates
        self.errorMessage = errorMessage
    }
}
