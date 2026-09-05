import Foundation

import SwiftData

@Model
final class SpeechItem {
    var id: UUID
    var schemaVersion: Int
    var title: String
    var cleanedText: String
    var createdAt: Date
    var updatedAt: Date
    var triggerSourceRawValue: String
    var modelIDRawValue: String
    var modelRevision: String
    var voice: String?
    var voiceModeRawValue: String?
    var voiceProfileID: UUID?
    var voiceProfileName: String?
    var language: String?
    var duration: Double
    var characterCount: Int
    var audioRelativePath: String?
    var audioByteCount: Int64
    var stateRawValue: String
    var failureCode: String?
    var isPinned: Bool
    var playbackTimingData: Data?

    init(
        id: UUID,
        title: String,
        cleanedText: String,
        createdAt: Date,
        triggerSourceRawValue: String,
        modelIDRawValue: String,
        modelRevision: String,
        voice: String?,
        voiceModeRawValue: String?,
        voiceProfileID: UUID?,
        voiceProfileName: String?,
        language: String?,
        characterCount: Int
    ) {
        self.id = id
        schemaVersion = 1
        self.title = title
        self.cleanedText = cleanedText
        self.createdAt = createdAt
        updatedAt = createdAt
        self.triggerSourceRawValue = triggerSourceRawValue
        self.modelIDRawValue = modelIDRawValue
        self.modelRevision = modelRevision
        self.voice = voice
        self.voiceModeRawValue = voiceModeRawValue
        self.voiceProfileID = voiceProfileID
        self.voiceProfileName = voiceProfileName
        self.language = language
        duration = 0
        self.characterCount = characterCount
        audioRelativePath = nil
        audioByteCount = 0
        stateRawValue = "generating"
        failureCode = nil
        isPinned = false
    }
}
