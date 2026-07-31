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
    var sortOrder: Int
    var tuning: VoiceTuning
    let generationSeed: UInt64?

    init(
        schemaVersion: Int,
        id: UUID,
        modelID: String,
        displayName: String,
        origin: VoiceProfileOrigin,
        language: String?,
        transcript: String?,
        duration: TimeInterval,
        referenceFilename: String,
        createdAt: Date,
        updatedAt: Date,
        sortOrder: Int,
        tuning: VoiceTuning,
        generationSeed: UInt64?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.modelID = modelID
        self.displayName = displayName
        self.origin = origin
        self.language = language
        self.transcript = transcript
        self.duration = duration
        self.referenceFilename = referenceFilename
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.tuning = tuning
        self.generationSeed = generationSeed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        modelID = try container.decode(String.self, forKey: .modelID)
        displayName = try container.decode(String.self, forKey: .displayName)
        origin = try container.decode(VoiceProfileOrigin.self, forKey: .origin)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        referenceFilename = try container.decode(
            String.self,
            forKey: .referenceFilename
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
            ?? 0
        tuning = try container.decode(VoiceTuning.self, forKey: .tuning)
        generationSeed = try container.decodeIfPresent(
            UInt64.self,
            forKey: .generationSeed
        )
    }

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
            sortOrder: sortOrder,
            tuning: tuning
        )
    }
}
