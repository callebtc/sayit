import Foundation
import SayItCore
import SayItProtocol

actor BackendMigrationCoordinator {
    private static let schemaVersion = 1

    func migrate(
        settings: BackendSettingsSnapshot
    ) throws {
        let source = try AppDirectories.live()
        let destination = try AppDirectories.shared(
            appGroupIdentifier: SayItServiceIdentifiers.appGroup
        )
        let marker = destination.applicationSupport.appending(
            path: "Migration v\(Self.schemaVersion).complete"
        )
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            return
        }

        let staging = destination.applicationSupport.appending(
            path: "Migration Staging v\(Self.schemaVersion)",
            directoryHint: .isDirectory
        )
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )

        do {
            try stageContents(
                from: source.applicationSupport,
                into: staging
            )
            try validate(staging)
            try mergeContents(
                from: staging,
                into: destination.applicationSupport
            )

            let settingsURL = destination.applicationSupport.appending(
                path: "Backend Settings.json"
            )
            if !FileManager.default.fileExists(atPath: settingsURL.path) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(settings).write(
                    to: settingsURL,
                    options: .atomic
                )
            }

            try Data("schema=\(Self.schemaVersion)\n".utf8).write(
                to: marker,
                options: .atomic
            )
            try FileManager.default.removeItem(at: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func stageContents(
        from source: URL,
        into staging: URL
    ) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        for item in try manager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) where !item.lastPathComponent.hasPrefix("Migration ") {
            let target = staging.appending(path: item.lastPathComponent)
            try manager.copyItem(at: item, to: target)
        }
    }

    private func validate(_ staging: URL) throws {
        let manager = FileManager.default
        let enumerator = manager.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "installation.json"
                || url.lastPathComponent == "CustomModels.json" {
                let data = try Data(contentsOf: url)
                _ = try JSONSerialization.jsonObject(with: data)
            }
        }
    }

    private func mergeContents(
        from source: URL,
        into destination: URL
    ) throws {
        let manager = FileManager.default
        for item in try manager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let target = destination.appending(path: item.lastPathComponent)
            if !manager.fileExists(atPath: target.path) {
                try manager.moveItem(at: item, to: target)
            } else if try item.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory == true {
                try mergeContents(from: item, into: target)
            }
        }
    }
}
