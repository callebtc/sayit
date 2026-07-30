import Foundation
import SayItCore
import SayItProtocol

struct HistoryItemSnapshot: Identifiable, Sendable {
    let id: UUID
    let title: String
    let cleanedText: String
    let createdAt: Date
    let modelID: ModelID
    let voice: String?
    let voiceSelection: VoiceSelection?
    let voiceProfileName: String?
    let language: String?
    let duration: TimeInterval
    let state: SpeechItemState
    let isPinned: Bool
    let hasAudio: Bool

    init(_ snapshot: HistorySnapshot) {
        id = snapshot.id
        title = snapshot.title
        cleanedText = snapshot.cleanedText
        createdAt = snapshot.createdAt
        modelID = ModelID(snapshot.modelID)
        voice = snapshot.voice
        voiceSelection = snapshot.voiceSelection
        voiceProfileName = snapshot.voiceProfileName
        language = snapshot.language
        duration = snapshot.duration
        state = SpeechItemState(rawValue: snapshot.state) ?? .failed
        isPinned = snapshot.isPinned
        hasAudio = snapshot.hasAudio
    }
}
