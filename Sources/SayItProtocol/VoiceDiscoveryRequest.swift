import Foundation

public struct VoiceDiscoveryRequest: Codable, Equatable, Sendable {
    public let modelID: String
    public let language: String?
    public let sampleText: String
    public let candidateCount: Int
    public let tuning: VoiceTuning
    public let candidateTunings: [VoiceTuning]?

    public init(
        modelID: String,
        language: String?,
        sampleText: String,
        candidateCount: Int = 4,
        tuning: VoiceTuning = VoiceTuning(),
        candidateTunings: [VoiceTuning]? = nil
    ) {
        self.modelID = modelID
        self.language = language
        self.sampleText = sampleText
        self.candidateCount = candidateCount
        self.tuning = tuning
        self.candidateTunings = candidateTunings
    }
}
