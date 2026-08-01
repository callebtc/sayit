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
    public let modelInstallError: ModelInstallErrorSnapshot?
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
        modelInstallError: ModelInstallErrorSnapshot? = nil,
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
        self.modelInstallError = modelInstallError
        self.installedModelIDs = installedModelIDs
        self.settings = settings
        self.modelsRevision = modelsRevision
        self.historyRevision = historyRevision
        self.diagnosticsRevision = diagnosticsRevision
        self.voicesRevision = voicesRevision
        self.voiceStudio = voiceStudio
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case serviceVersion
        case revision
        case statusText
        case lastError
        case httpServiceError
        case activeJob
        case queuedJobs
        case playback
        case download
        case modelInstallError
        case installedModelIDs
        case settings
        case modelsRevision
        case historyRevision
        case diagnosticsRevision
        case voicesRevision
        case voiceStudio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(
            Int.self,
            forKey: .protocolVersion
        )
        serviceVersion = try container.decode(
            String.self,
            forKey: .serviceVersion
        )
        revision = try container.decode(UInt64.self, forKey: .revision)
        statusText = try container.decode(String.self, forKey: .statusText)
        lastError = try container.decodeIfPresent(
            String.self,
            forKey: .lastError
        )
        httpServiceError = try container.decodeIfPresent(
            String.self,
            forKey: .httpServiceError
        )
        activeJob = try container.decodeIfPresent(
            SpeechJob.self,
            forKey: .activeJob
        )
        queuedJobs = try container.decode(
            [SpeechJob].self,
            forKey: .queuedJobs
        )
        playback = try container.decode(
            PlaybackSnapshot.self,
            forKey: .playback
        )
        download = try container.decodeIfPresent(
            DownloadSnapshot.self,
            forKey: .download
        )
        modelInstallError = try container.decodeIfPresent(
            ModelInstallErrorSnapshot.self,
            forKey: .modelInstallError
        )
        installedModelIDs = try container.decode(
            [String].self,
            forKey: .installedModelIDs
        )
        settings = try container.decode(
            BackendSettingsSnapshot.self,
            forKey: .settings
        )
        modelsRevision = try container.decode(
            UInt64.self,
            forKey: .modelsRevision
        )
        historyRevision = try container.decode(
            UInt64.self,
            forKey: .historyRevision
        )
        diagnosticsRevision = try container.decode(
            UInt64.self,
            forKey: .diagnosticsRevision
        )
        voicesRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .voicesRevision
        ) ?? 0
        voiceStudio = try container.decodeIfPresent(
            VoiceStudioSnapshot.self,
            forKey: .voiceStudio
        )
    }
}
