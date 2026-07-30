import Foundation

public struct VoiceCloneRequest: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let modelID: String
    public let language: String?
    public let transcript: String
    public let tuning: VoiceTuning

    public init(
        recordingID: UUID,
        modelID: String,
        language: String?,
        transcript: String,
        tuning: VoiceTuning
    ) {
        self.recordingID = recordingID
        self.modelID = modelID
        self.language = language
        self.transcript = transcript
        self.tuning = tuning
    }
}
