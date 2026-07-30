import Foundation
import SayItProtocol

struct VoiceCloneDraft: Sendable {
    let sessionID: UUID
    let recordingID: UUID
    let modelID: String
    let language: String?
    let transcript: String?
    let duration: TimeInterval
    let tuning: VoiceTuning
    let referenceURL: URL
}
