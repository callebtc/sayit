import Foundation

public struct VoiceDiscoveryRequest: Codable, Equatable, Sendable {
    public let modelID: String
    public let language: String?
    public let sampleText: String
    public let candidateCount: Int
    public let tuning: VoiceTuning

    public init(
        modelID: String,
        language: String?,
        sampleText: String,
        candidateCount: Int = 4,
        tuning: VoiceTuning = VoiceTuning()
    ) {
        self.modelID = modelID
        self.language = language
        self.sampleText = sampleText
        self.candidateCount = candidateCount
        self.tuning = tuning
    }
}
