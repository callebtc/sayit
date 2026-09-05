import Foundation

public struct AppDirectories: Sendable {
    public let applicationSupport: URL
    public let models: URL
    public let historyAudio: URL
    public let diagnostics: URL
    public let hubCache: URL
    public let temporary: URL
    public let downloads: URL
    public let voiceProfiles: URL
    public let voiceDrafts: URL

    public init(
        applicationSupport: URL,
        models: URL,
        historyAudio: URL,
        diagnostics: URL,
        hubCache: URL,
        temporary: URL,
        downloads: URL,
        voiceProfiles: URL,
        voiceDrafts: URL
    ) {
        self.applicationSupport = applicationSupport
        self.models = models
        self.historyAudio = historyAudio
        self.diagnostics = diagnostics
        self.hubCache = hubCache
        self.temporary = temporary
        self.downloads = downloads
        self.voiceProfiles = voiceProfiles
        self.voiceDrafts = voiceDrafts
    }

    public static func live() throws -> AppDirectories {
        let support = URL.applicationSupportDirectory
            .appending(path: "Say It", directoryHint: .isDirectory)
        let caches = URL.cachesDirectory
            .appending(path: "Say It", directoryHint: .isDirectory)
        return try create(applicationSupport: support, caches: caches)
    }

    public static func shared(
        appGroupIdentifier: String
    ) throws -> AppDirectories {
#if DEBUG || SAYIT_LOCAL_BUILD
        if ProcessInfo.processInfo.environment[
            "SAYIT_USE_APP_GROUP_CONTAINER"
        ] != "1" {
            return try debugServiceDirectories()
        }
#endif
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
#if DEBUG || SAYIT_LOCAL_BUILD
            return try debugServiceDirectories()
#else
            throw CocoaError(.fileNoSuchFile)
#endif
        }
        return try create(
            applicationSupport: container.appending(
                path: "Library/Application Support/Say It",
                directoryHint: .isDirectory
            ),
            caches: container.appending(
                path: "Library/Caches/Say It",
                directoryHint: .isDirectory
            )
        )
    }

#if DEBUG || SAYIT_LOCAL_BUILD
    private static func debugServiceDirectories() throws -> AppDirectories {
#if SAYIT_MODEL_AUDIT_BUILD
        let directoryName = "Say It Model Audit"
#else
        let directoryName = "Say It Service (Debug)"
#endif
        let support = URL.applicationSupportDirectory.appending(
            path: directoryName,
            directoryHint: .isDirectory
        )
        let caches = URL.cachesDirectory.appending(
            path: directoryName,
            directoryHint: .isDirectory
        )
        return try create(applicationSupport: support, caches: caches)
    }
#endif

    public static func testing(root: URL) throws -> AppDirectories {
        try create(
            applicationSupport: root.appending(
                path: "Application Support",
                directoryHint: .isDirectory
            ),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
    }

    private static func create(
        applicationSupport support: URL,
        caches: URL
    ) throws -> AppDirectories {
        let directories = AppDirectories(
            applicationSupport: support,
            models: support.appending(path: "Models", directoryHint: .isDirectory),
            historyAudio: support.appending(
                path: "History Audio",
                directoryHint: .isDirectory
            ),
            diagnostics: support.appending(
                path: "Diagnostics",
                directoryHint: .isDirectory
            ),
            hubCache: support.appending(
                path: "Hugging Face",
                directoryHint: .isDirectory
            ),
            temporary: caches.appending(path: "Generation", directoryHint: .isDirectory),
            downloads: caches.appending(path: "Downloads", directoryHint: .isDirectory),
            voiceProfiles: support.appending(
                path: "Voice Profiles",
                directoryHint: .isDirectory
            ),
            voiceDrafts: caches.appending(
                path: "Voice Studio",
                directoryHint: .isDirectory
            )
        )
        for url in [
            directories.applicationSupport,
            directories.models,
            directories.historyAudio,
            directories.diagnostics,
            directories.hubCache,
            directories.temporary,
            directories.downloads,
            directories.voiceProfiles,
            directories.voiceDrafts
        ] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        return directories
    }
}
