import Foundation

@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon
import SayItCore

/// The one production speech-model adapter: per-family MLX model loading
/// and text-processor dependency preparation.
struct LiveSpeechModelLoader: SpeechModelLoading {
    func load(
        model: ModelDescriptor,
        directory: URL
    ) async throws -> any SpeechModelSession {
        let textProcessor = Self.makeTextProcessor(for: model)
        let candidate: SpeechGenerationModel
        do {
            switch model.modelType.lowercased() {
            case "omnivoice":
                let hubCache = ProcessInfo.processInfo.environment[
                    "HF_HUB_CACHE"
                ].map {
                    URL(filePath: $0, directoryHint: .isDirectory)
                } ?? directory.deletingLastPathComponent()
                let repository = try MLXAudioLocalModelBridge
                    .repositoryIdentifier(
                        modelType: model.modelType,
                        repository: model.repository,
                        localDirectory: directory,
                        hubCache: hubCache
                    ) ?? model.repository
                candidate = try await TTS.loadModel(
                    modelRepo: repository,
                    modelType: model.modelType,
                    textProcessor: textProcessor
                )
            case "kitten", "kitten_tts":
                try KittenVoiceArchiveConverter.prepareVoices(in: directory)
                candidate = try await TTS.loadModel(
                    modelRepo: directory.path,
                    modelType: model.modelType,
                    textProcessor: textProcessor
                )
            case "soprano", "soprano_tts":
                candidate = try await SopranoModel.fromModelDirectory(
                    directory,
                    repo: model.repository
                )
            default:
                candidate = try await TTS.loadModel(
                    modelRepo: directory.path,
                    modelType: model.modelType,
                    textProcessor: textProcessor
                )
            }
        } catch {
            Stream.gpu.synchronize()
            Memory.clearCache()
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            Stream.gpu.synchronize()
            withExtendedLifetime(candidate) {}
            Memory.clearCache()
            throw error
        }
        return LiveSpeechModelSession(
            descriptor: model,
            model: candidate,
            textProcessor: textProcessor
        )
    }

    func prepareDependencies(for model: ModelDescriptor) async throws {
        switch model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            let processor = KokoroMultilingualProcessor()
            for language in model.languages {
                try Task.checkCancellation()
                try await processor.prepare(for: language)
            }
        case "kitten", "kitten_tts":
            try await MisakiTextProcessor().prepare()
        default:
            break
        }
    }

    private static func makeTextProcessor(
        for model: ModelDescriptor
    ) -> (any TextProcessor)? {
        switch model.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            KokoroMultilingualProcessor()
        case "kitten", "kitten_tts":
            MisakiTextProcessor()
        default:
            nil
        }
    }
}
