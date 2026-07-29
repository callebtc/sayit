import Foundation

public struct SpeechSubmission: Codable, Sendable {
    public let text: String
    public let inputFormat: InputFormat
    public let representationData: Data?
    public let source: SpeechJobSource
    public let modelID: String?
    public let voice: String?
    public let language: String?
    public let voiceDescription: String?
    public let speakingPace: Double?
    public let playbackRate: Double?
    public let queuePolicy: QueuePolicy
    public let permitsLongText: Bool

    public init(
        text: String,
        inputFormat: InputFormat = .plainText,
        representationData: Data? = nil,
        source: SpeechJobSource,
        modelID: String? = nil,
        voice: String? = nil,
        language: String? = nil,
        voiceDescription: String? = nil,
        speakingPace: Double? = nil,
        playbackRate: Double? = nil,
        queuePolicy: QueuePolicy = .enqueue,
        permitsLongText: Bool = false
    ) {
        self.text = text
        self.inputFormat = inputFormat
        self.representationData = representationData
        self.source = source
        self.modelID = modelID
        self.voice = voice
        self.language = language
        self.voiceDescription = voiceDescription
        self.speakingPace = speakingPace
        self.playbackRate = playbackRate
        self.queuePolicy = queuePolicy
        self.permitsLongText = permitsLongText
    }
}
