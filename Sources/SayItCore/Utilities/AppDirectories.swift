import Foundation

public struct AppDirectories: Sendable {
    public let applicationSupport: URL
    public let models: URL
    public let historyAudio: URL
    public let diagnostics: URL
    public let hubCache: URL
    public let temporary: URL
    public let downloads: URL

    public init(
        applicationSupport: URL,
        models: URL,
        historyAudio: URL,
        diagnostics: URL,
        hubCache: URL,
        temporary: URL,
        downloads: URL
    ) {
        self.applicationSupport = applicationSupport
        self.models = models
        self.historyAudio = historyAudio
        self.diagnostics = diagnostics
        self.hubCache = hubCache
        self.temporary = temporary
        self.downloads = downloads
    }

    public static func live() throws -> AppDirectories {
        let support = URL.applicationSupportDirectory
            .appending(path: "Say It", directoryHint: .isDirectory)
        let caches = URL.cachesDirectory
            .appending(path: "Say It", directoryHint: .isDirectory)
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
            downloads: caches.appending(path: "Downloads", directoryHint: .isDirectory)
        )
        for url in [
            directories.applicationSupport,
            directories.models,
            directories.historyAudio,
            directories.diagnostics,
            directories.hubCache,
            directories.temporary,
            directories.downloads
        ] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        return directories
    }
}
