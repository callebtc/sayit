import CryptoKit
import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Model manager", .serialized)
struct ModelManagerTests {
    @Test("A complete staged snapshot installs, reports progress, and removes")
    func stagedInstallLifecycle() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItModelTests")
        defer { fixture.remove() }
        let config = try JSONSerialization.data(
            withJSONObject: ["model_type": "qwen3_tts"]
        )
        let weights = Data([1, 2, 3, 4])
        let model = makeModel(
            id: "test-model",
            revision: "revision-a",
            files: [
                ModelFileDescriptor(
                    path: "config.json",
                    byteCount: Int64(config.count),
                    sha256: sha256(config)
                ),
                ModelFileDescriptor(
                    path: "nested/model.safetensors",
                    byteCount: Int64(weights.count),
                    sha256: sha256(weights)
                )
            ]
        )
        let manager = ModelManager(
            catalog: makeCatalog(models: [model]),
            directories: fixture.directories,
            activeModelID: ModelID("different-model")
        )
        let staging = fixture.directories.downloads.appending(
            path: "test-model-revision-a.partial"
        )
        try FileManager.default.createDirectory(
            at: staging.appending(path: "nested"),
            withIntermediateDirectories: true
        )
        try config.write(to: staging.appending(path: "config.json"))
        try weights.write(
            to: staging.appending(path: "nested/model.safetensors")
        )
        let progress = ProgressRecorder()

        try await manager.install(model.id) { value in
            await progress.append(value)
        }

        let updates = await progress.values
        #expect(updates.first?.state == .downloading)
        #expect(updates.contains { $0.state == .verifying })
        #expect(updates.last?.state == .installed)
        #expect(updates.last?.completedBytes == model.downloadByteCount)
        #expect(await manager.installedModelIDs() == [model.id])
        let installedURL = try #require(
            await manager.installedURL(for: model.id)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: installedURL.appending(path: "installation.json").path
            )
        )

        try await manager.install(model.id)
        try await manager.select(model.id)
        await #expect(throws: ModelManagerError.self) {
            try await manager.remove(model.id)
        }

        let removableManager = ModelManager(
            catalog: makeCatalog(models: [model]),
            directories: fixture.directories,
            activeModelID: ModelID("different-model")
        )
        try await removableManager.remove(model.id)
        #expect(await removableManager.installedModelIDs().isEmpty)
        #expect(await removableManager.installedURL(for: model.id) == nil)
    }

    @Test("Install and selection reject unknown, unavailable, and invalid snapshots")
    func installValidationFailures() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItModelTests")
        defer { fixture.remove() }
        let unavailable = makeModel(
            id: "reference-only",
            stability: .unavailable,
            requiresReference: true
        )
        let invalid = makeModel(
            id: "invalid-snapshot",
            revision: "invalid-revision",
            files: [
                ModelFileDescriptor(
                    path: "config.json",
                    byteCount: 29,
                    sha256: nil
                ),
                ModelFileDescriptor(
                    path: "model.safetensors",
                    byteCount: 1,
                    sha256: sha256(Data([1]))
                )
            ]
        )
        let manager = ModelManager(
            catalog: makeCatalog(models: [unavailable, invalid]),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )

        await #expect(throws: ModelManagerError.self) {
            try await manager.install(ModelID("unknown"))
        }
        await #expect(throws: ModelManagerError.self) {
            try await manager.install(unavailable.id)
        }
        await #expect(throws: ModelManagerError.self) {
            try await manager.select(ModelID("unknown"))
        }
        await #expect(throws: ModelManagerError.self) {
            try await manager.select(unavailable.id)
        }
        await #expect(throws: ModelManagerError.self) {
            try await manager.select(invalid.id)
        }
        try await manager.remove(ModelID("unknown"))
        await manager.cancelInstall(ModelID("unknown"))

        let staging = fixture.directories.downloads.appending(
            path: "invalid-snapshot-invalid-revision.partial"
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        let wrongType = Data(#"{"model_type":"unsupported"}"#.utf8)
        #expect(wrongType.count == 28)
        let paddedWrongType = wrongType + Data([0x20])
        try paddedWrongType.write(to: staging.appending(path: "config.json"))
        try Data([1]).write(
            to: staging.appending(path: "model.safetensors")
        )

        await #expect(throws: ModelManagerError.self) {
            try await manager.install(invalid.id)
        }
    }

    @Test("Checksum mismatches remove the corrupt staged file")
    func checksumMismatchRemovesFile() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItModelTests")
        defer { fixture.remove() }
        let config = Data(#"{"model_type":"qwen3_tts"}"#.utf8)
        let expectedWeights = Data([1, 2, 3, 4])
        let model = makeModel(
            id: "checksum-model",
            revision: "checksum-revision",
            files: [
                .init(
                    path: "config.json",
                    byteCount: Int64(config.count),
                    sha256: nil
                ),
                .init(
                    path: "model.safetensors",
                    byteCount: Int64(expectedWeights.count),
                    sha256: sha256(expectedWeights)
                )
            ]
        )
        let manager = ModelManager(
            catalog: makeCatalog(models: [model]),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )
        let staging = fixture.directories.downloads.appending(
            path: "checksum-model-checksum-revision.partial"
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try config.write(to: staging.appending(path: "config.json"))
        let corruptURL = staging.appending(path: "model.safetensors")
        try Data([4, 3, 2, 1]).write(to: corruptURL)

        await #expect(throws: ModelManagerError.self) {
            try await manager.install(model.id)
        }
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test("Managed dependencies must be explicitly verified after install")
    func managedDependencyLifecycle() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItModelTests")
        defer { fixture.remove() }
        let config = Data(#"{"model_type":"kitten_tts"}"#.utf8)
        let weights = Data([9])
        let dependencyConfig = Data(#"{"dependency":true}"#.utf8)
        let dependency = ModelDependencyDescriptor(
            id: "kitten-tts-g2p",
            modelTypes: ["kitten_tts"],
            repository: "owner/dependency",
            revision: "dep-revision",
            targetSubdirectory: "kitten-g2p",
            files: [
                .init(
                    path: "us_bart_config.json",
                    byteCount: Int64(dependencyConfig.count),
                    sha256: nil
                )
            ]
        )
        let model = makeModel(
            id: "kitten-model",
            revision: "kitten-revision",
            modelType: "kitten_tts",
            files: [
                .init(
                    path: "config.json",
                    byteCount: Int64(config.count),
                    sha256: nil
                ),
                .init(
                    path: "model.safetensors",
                    byteCount: 1,
                    sha256: nil
                )
            ]
        )
        let manager = ModelManager(
            catalog: makeCatalog(
                models: [model],
                dependencies: [dependency]
            ),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )
        let staging = fixture.directories.downloads.appending(
            path: "kitten-model-kitten-revision.partial"
        )
        let dependencyStaging = staging.appending(
            path: "__dependencies/kitten-tts-g2p"
        )
        try FileManager.default.createDirectory(
            at: dependencyStaging,
            withIntermediateDirectories: true
        )
        try config.write(to: staging.appending(path: "config.json"))
        try weights.write(to: staging.appending(path: "model.safetensors"))
        try dependencyConfig.write(
            to: dependencyStaging.appending(path: "us_bart_config.json")
        )

        try await manager.install(model.id)

        #expect(await manager.installedModelIDs().isEmpty)
        #expect(await manager.installedURL(for: model.id) == nil)
        let dependencyURL = fixture.directories.hubCache
            .appending(path: "mlx-audio/kitten-g2p")
        #expect(
            FileManager.default.fileExists(
                atPath: dependencyURL.appending(path: "config.json").path
            )
        )

        try await manager.markDependenciesVerified(model.id)
        #expect(await manager.installedModelIDs() == [model.id])
        #expect(await manager.installedURL(for: model.id) != nil)

        try await manager.remove(model.id)
        #expect(!FileManager.default.fileExists(atPath: dependencyURL.path))
        await #expect(throws: ModelManagerError.self) {
            try await manager.markDependenciesVerified(model.id)
        }
    }

    @Test("Local imports persist custom descriptors and can be replaced")
    func localImportAndCustomModelPersistence() async throws {
        let fixture = try TemporaryBackendFixture(prefix: "SayItModelTests")
        defer { fixture.remove() }
        let source = fixture.root.appending(path: "source")
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data(#"{"model_type":"qwen3_tts"}"#.utf8).write(
            to: source.appending(path: "config.json")
        )
        try Data([1, 2, 3]).write(
            to: source.appending(path: "model.safetensors")
        )
        let model = makeModel(
            id: "community-local-test",
            revision: "local-revision",
            repository: "local-import",
            estimatedDiskBytes: 3
        )
        let manager = ModelManager(
            catalog: makeCatalog(models: []),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )

        try await manager.importLocalModel(model, from: source)
        #expect(await manager.models().map(\.id) == [model.id])
        #expect(await manager.installedModelIDs() == [model.id])

        let replacement = makeModel(
            id: "community-local-test",
            displayName: "Replacement",
            revision: "local-revision",
            repository: "local-import",
            estimatedDiskBytes: 3
        )
        try await manager.addCommunityModel(replacement)
        #expect(await manager.models().first?.displayName == "Replacement")

        let reloaded = ModelManager(
            catalog: makeCatalog(models: []),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )
        #expect(await reloaded.models().first?.displayName == "Replacement")

        try await reloaded.remove(model.id)
        #expect(await reloaded.models().isEmpty)
        let afterRemoval = ModelManager(
            catalog: makeCatalog(models: []),
            directories: fixture.directories,
            activeModelID: ModelID("active")
        )
        #expect(await afterRemoval.models().isEmpty)
    }
}

private actor ProgressRecorder {
    private(set) var values: [ModelDownloadProgress] = []

    func append(_ value: ModelDownloadProgress) {
        values.append(value)
    }
}

private func makeCatalog(
    models: [ModelDescriptor],
    dependencies: [ModelDependencyDescriptor] = []
) -> ModelCatalog {
    ModelCatalog(
        schemaVersion: 1,
        generatedAt: "test",
        dependencies: dependencies,
        models: models
    )
}

private func makeModel(
    id: String,
    displayName: String = "Test Model",
    revision: String = "revision",
    repository: String = "owner/model",
    modelType: String = "qwen3_tts",
    files: [ModelFileDescriptor] = [],
    estimatedDiskBytes: Int64 = 1,
    stability: ModelStability = .stable,
    requiresReference: Bool = false
) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID(id),
        displayName: displayName,
        family: "Tests",
        repository: repository,
        revision: revision,
        modelType: modelType,
        parameterCount: "1",
        quantization: "none",
        languages: ["en"],
        voices: ["test-voice"],
        defaultVoice: "test-voice",
        defaultLanguage: "en",
        capabilities: ModelCapabilities(
            presetVoices: true,
            voiceDescription: false,
            voiceCloning: false,
            streaming: false,
            longForm: true,
            languageSelection: true,
            requiresReferenceAudio: requiresReference
        ),
        playbackMode: .buffered,
        files: files,
        estimatedDiskBytes: estimatedDiskBytes,
        estimatedPeakMemoryBytes: 1,
        hardwareTier: .base,
        license: ModelLicense(
            identifier: "test",
            url: URL(string: "https://example.invalid")!,
            commercialUseAllowed: true,
            requiresAcceptance: false
        ),
        stability: stability,
        testedMLXAudioVersion: "test",
        testedDate: "test"
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String($0, radix: 16).leftPadding(toLength: 2, withPad: "0")
    }.joined()
}
