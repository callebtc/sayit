import Foundation
import Testing
@testable import SayItBackend

@Suite("MLX Audio local model bridge")
struct MLXAudioLocalModelBridgeTests {
    @Test("OmniVoice uses the verified local snapshot through MLX Audio cache")
    func bridgesOmniVoiceWithoutCopyingWeights() throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItMLXAudioBridgeTests"
        )
        defer { fixture.remove() }
        let localDirectory = fixture.root.appending(
            path: "installed-model",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: localDirectory,
            withIntermediateDirectories: true
        )
        let localWeights = localDirectory.appending(path: "model.safetensors")
        try Data([1, 2, 3]).write(to: localWeights)

        let bridgedRepository = try MLXAudioLocalModelBridge
            .repositoryIdentifier(
                modelType: "omnivoice",
                repository: "owner/OmniVoice-bfloat16",
                localDirectory: localDirectory,
                hubCache: fixture.directories.hubCache
            )
        let repository = try #require(bridgedRepository)

        #expect(repository == "owner/OmniVoice-bfloat16")
        let alias = fixture.directories.hubCache.appending(
            path: "mlx-audio/owner_OmniVoice-bfloat16"
        )
        #expect(try alias.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let cachedWeights = alias.appending(path: "model.safetensors")
        let localIdentifier = try localWeights.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier as? AnyHashable
        let cachedIdentifier = try cachedWeights.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier as? AnyHashable
        #expect(localIdentifier != nil)
        #expect(cachedIdentifier == localIdentifier)

        try MLXAudioLocalModelBridge.removeAliasIfPresent(
            modelType: "omnivoice",
            repository: repository,
            hubCache: fixture.directories.hubCache
        )
        #expect(
            (try? FileManager.default.attributesOfItem(atPath: alias.path))
                == nil
        )
    }

    @Test("Other model types do not create repository aliases")
    func ignoresModelsWithNativeLocalLoading() throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItMLXAudioBridgeTests"
        )
        defer { fixture.remove() }

        let repository = try MLXAudioLocalModelBridge.repositoryIdentifier(
            modelType: "kokoro",
            repository: "owner/model",
            localDirectory: fixture.root,
            hubCache: fixture.directories.hubCache
        )

        #expect(repository == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.hubCache
                    .appending(path: "mlx-audio/owner_model")
                    .path
            )
        )
    }
}
