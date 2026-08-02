import Foundation

enum MLXAudioLocalModelBridge {
    static func repositoryIdentifier(
        modelType: String,
        repository: String,
        localDirectory: URL,
        hubCache: URL
    ) throws -> String? {
        guard modelType.lowercased() == "omnivoice" else {
            return nil
        }
        guard isValidRepository(repository) else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let cacheDirectory = repositoryCacheDirectory(
            repository: repository,
            hubCache: hubCache
        )
        let parent = cacheDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let staging = parent.appending(
            path: ".sayit-\(UUID().uuidString).cache",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
            try materializeHardLinks(
                from: localDirectory,
                to: staging
            )
            try Data().write(to: staging.appending(path: bridgeMarker))
            if itemExists(at: cacheDirectory) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            try FileManager.default.moveItem(at: staging, to: cacheDirectory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return repository
    }

    static func removeAliasIfPresent(
        modelType: String,
        repository: String,
        hubCache: URL
    ) throws {
        guard modelType.lowercased() == "omnivoice",
              isValidRepository(repository) else {
            return
        }
        let cacheDirectory = repositoryCacheDirectory(
            repository: repository,
            hubCache: hubCache
        )
        if FileManager.default.fileExists(
            atPath: cacheDirectory.appending(path: bridgeMarker).path
        ) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private static func repositoryCacheDirectory(
        repository: String,
        hubCache: URL
    ) -> URL {
        hubCache
            .appending(path: "mlx-audio", directoryHint: .isDirectory)
            .appending(
                path: repository.replacingOccurrences(of: "/", with: "_")
            )
    }

    private static func isValidRepository(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        return components.allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func materializeHardLinks(
        from source: URL,
        to destination: URL
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let items = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: keys,
            options: []
        )
        for item in items {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let target = destination.appending(
                path: item.lastPathComponent,
                directoryHint: values.isDirectory == true
                    ? .isDirectory
                    : .notDirectory
            )
            if values.isDirectory == true {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
                try materializeHardLinks(from: item, to: target)
            } else if values.isRegularFile == true {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.linkItem(at: item, to: target)
            }
        }
    }

    private static let bridgeMarker = ".sayit-local-model-bridge"
}
