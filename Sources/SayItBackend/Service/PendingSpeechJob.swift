import Foundation
import SayItCore
import SayItProtocol

struct PendingSpeechJob: Codable, Sendable {
    let submission: SpeechSubmission
    var cleanedText: CleanedText?
}
