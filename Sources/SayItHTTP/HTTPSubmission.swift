import Foundation
import SayItProtocol

struct HTTPSubmission: Codable, Sendable {
    let text: String
    var inputFormat: InputFormat?
    var modelID: String?
    var voice: String?
    var language: String?
    var voiceDescription: String?
    var speakingPace: Double?
    var playbackRate: Double?
    var queuePolicy: QueuePolicy?
    var permitsLongText: Bool?

    var serviceSubmission: SpeechSubmission {
        SpeechSubmission(
            text: text,
            inputFormat: inputFormat ?? .plainText,
            source: .http,
            modelID: modelID,
            voice: voice,
            language: language,
            voiceDescription: voiceDescription,
            speakingPace: speakingPace,
            playbackRate: playbackRate,
            queuePolicy: queuePolicy ?? .enqueue,
            permitsLongText: permitsLongText ?? false
        )
    }
}
