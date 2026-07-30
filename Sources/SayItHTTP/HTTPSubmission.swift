import Foundation
import SayItProtocol

struct HTTPSubmission: Codable, Sendable {
    let text: String
    var inputFormat: InputFormat?
    var modelID: String?
    var voice: String?
    var voiceSelection: VoiceSelection?
    var language: String?
    var voiceDescription: String?
    var speakingPace: Double?
    var playbackRate: Double?
    var queuePolicy: QueuePolicy?
    var permitsLongText: Bool?

    func serviceSubmission() throws -> SpeechSubmission {
        guard voice == nil || voiceSelection == nil else {
            throw HTTPAPIError(
                status: 400,
                code: "voice.conflicting_selection",
                message: "Choose either voice or voiceSelection, not both."
            )
        }
        return SpeechSubmission(
            text: text,
            inputFormat: inputFormat ?? .plainText,
            source: .http,
            modelID: modelID,
            voice: voice,
            voiceSelection: voiceSelection,
            language: language,
            voiceDescription: voiceDescription,
            speakingPace: speakingPace,
            playbackRate: playbackRate,
            queuePolicy: queuePolicy ?? .enqueue,
            permitsLongText: permitsLongText ?? false
        )
    }
}
