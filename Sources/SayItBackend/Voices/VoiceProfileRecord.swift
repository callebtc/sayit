import Foundation
import SayItProtocol

struct VoiceProfileRecord: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let modelID: String
    var displayName: String
    let origin: VoiceProfileOrigin
    let language: String?
    let transcript: String?
    let duration: TimeInterval
    let referenceFilename: String
    let createdAt: Date
    var updatedAt: Date
    var tuning: VoiceTuning
    let generationSeed: UInt64?

    var snapshot: VoiceProfileSnapshot {
        VoiceProfileSnapshot(
            id: id,
            modelID: modelID,
            displayName: displayName,
            origin: origin,
            language: language,
            duration: duration,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tuning: tuning
        )
    }
}
