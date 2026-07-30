import Foundation
import SayItProtocol

struct VoiceDraftCandidate: Sendable {
    let snapshot: VoiceCandidateSnapshot
    let modelID: String
    let language: String?
    let transcript: String
    let tuning: VoiceTuning
    let generationSeed: UInt64
    let audioURL: URL
}
