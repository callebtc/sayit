import Foundation

public enum ServiceCommand: Codable, Sendable {
    case snapshot
    case events(after: UInt64)
    case waitForEvents(after: UInt64, playbackInterval: TimeInterval)
    case submit(SpeechSubmission)
    case jobs
    case confirmJob(UUID)
    case cancelJob(UUID)
    case play
    case pause
    case clear
    case clearError
    case seek(TimeInterval)
    case skip(TimeInterval)
    case setPlaybackRate(Double)
    case setVolume(Double)
    case models
    case selectModel(String)
    case installModel(String)
    case cancelModelInstall
    case removeModel(String)
    case voices(modelID: String?)
    case startVoiceDiscovery(VoiceDiscoveryRequest)
    case startVoiceClone(VoiceCloneRequest)
    case cancelVoiceStudio
    case voicePreview(UUID)
    case saveVoiceCandidate(UUID, name: String, tuning: VoiceTuning)
    case regenerateVoiceCandidate(UUID, tuning: VoiceTuning)
    case saveVoiceClone(UUID, name: String)
    case selectVoice(UUID)
    case renameVoice(UUID, name: String)
    case reorderVoices(modelID: String, orderedIDs: [UUID])
    case updateVoiceTuning(UUID, VoiceTuning)
    case duplicateVoiceProfile(UUID, name: String, tuning: VoiceTuning)
    case previewVoiceProfile(UUID, tuning: VoiceTuning, text: String)
    case deleteVoice(UUID)
    case addCommunityModel(
        repository: String,
        revision: String?,
        accessToken: String?
    )
    case importLocalModel(bookmark: Data)
    case history
    case exportHistory(UUID, format: String)
    case replayHistory(UUID)
    case regenerateHistory(UUID)
    case switchPlaybackModel(String)
    case toggleHistoryPinned(UUID)
    case deleteHistory(UUID)
    case clearHistory
    case diagnostics
    case exportDiagnostics
    case clearDiagnostics
    case updateSettings(BackendSettingsSnapshot)
    case tokens
    case createToken(name: String, scopes: Set<APITokenScope>)
    case revokeToken(UUID)
}
