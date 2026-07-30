import Foundation

public struct ServiceSnapshot: Codable, Sendable {
    public let protocolVersion: Int
    public let serviceVersion: String
    public let revision: UInt64
    public let statusText: String
    public let lastError: String?
    public let httpServiceError: String?
    public let activeJob: SpeechJob?
    public let queuedJobs: [SpeechJob]
    public let playback: PlaybackSnapshot
    public let download: DownloadSnapshot?
    public let installedModelIDs: [String]
    public let settings: BackendSettingsSnapshot
    public let modelsRevision: UInt64
    public let historyRevision: UInt64
    public let diagnosticsRevision: UInt64
    public let voicesRevision: UInt64
    public let voiceStudio: VoiceStudioSnapshot?

    public init(
        protocolVersion: Int = SayItProtocolVersion.current,
        serviceVersion: String,
        revision: UInt64,
        statusText: String,
        lastError: String?,
        httpServiceError: String? = nil,
        activeJob: SpeechJob?,
        queuedJobs: [SpeechJob],
        playback: PlaybackSnapshot,
        download: DownloadSnapshot?,
        installedModelIDs: [String],
        settings: BackendSettingsSnapshot,
        modelsRevision: UInt64,
        historyRevision: UInt64,
        diagnosticsRevision: UInt64,
        voicesRevision: UInt64 = 0,
        voiceStudio: VoiceStudioSnapshot? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.serviceVersion = serviceVersion
        self.revision = revision
        self.statusText = statusText
        self.lastError = lastError
        self.httpServiceError = httpServiceError
        self.activeJob = activeJob
        self.queuedJobs = queuedJobs
        self.playback = playback
        self.download = download
        self.installedModelIDs = installedModelIDs
        self.settings = settings
        self.modelsRevision = modelsRevision
        self.historyRevision = historyRevision
        self.diagnosticsRevision = diagnosticsRevision
        self.voicesRevision = voicesRevision
        self.voiceStudio = voiceStudio
    }
}
