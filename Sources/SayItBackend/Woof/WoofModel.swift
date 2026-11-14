import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import SayItCore

/// Runs Underdog Woof from its original `woof_int8.npz` release with MLX.
///
/// Text is normalized for speech and spoken one sentence-sized utterance at a
/// time; `SynthesisActor` sends one sentence per chunk so playback starts early.
/// A take that stalls or runs on is drawn again, keeping the best of four.
///
/// Like other MLX Audio models, an instance is only used while
/// `SynthesisOperationGate` is held, so it is never accessed concurrently.
final class WoofModel: SpeechGenerationModel, @unchecked Sendable {
    static let weightsFileName = "woof_int8.npz"
    static let defaultVoice = "juno"
    private static let retakeLimit = 3
    /// Woof speaks one sentence at a time and splits sentences over 120
    /// characters at a clause boundary; an utterance cut mid-clause can stall.
    static let sentenceChunker = TextChunker(targetCharacterCount: 1)
    private static let utteranceCharacterLimit = 120

    let sampleRate = 24_000

    var defaultGenerationParameters: GenerateParameters {
        GenerateParameters(temperature: 0.5)
    }

    private let speech: WoofSpeechModel
    private let decoder: WoofDecoder
    private let voices: [String: MLXArray]
    private let latentMean: MLXArray
    private let latentDeviation: MLXArray
    private let maximumFrames: Int
    private let normalizer = WoofTextNormalizer()

    init(directory: URL) throws {
        let archive = try NumPyArchive(
            contentsOf: directory.appending(path: Self.weightsFileName)
        )
        let tree = try WoofWeightTree(archive: archive)
        speech = try WoofSpeechModel(tree: tree.child("speech"))
        decoder = try WoofDecoder(tree: tree.child("decoder"))
        let voiceTree = try tree.child("voices")
        voices = try Dictionary(uniqueKeysWithValues: voiceTree.keys.map {
            ($0, try voiceTree.child($0).tensor())
        })
        latentMean = try tree.child("mean").tensor()
        latentDeviation = try tree.child("std").tensor()
        maximumFrames = try tree.child("max_frames").int()
        guard voices[Self.defaultVoice] != nil,
              latentMean.dim(0) == speech.latentWidth,
              latentDeviation.dim(0) == speech.latentWidth else {
            throw WoofModelError.invalidWeights("voices or latent statistics are inconsistent")
        }
    }

    func generate(
        text: String,
        voice: String?,
        refAudio: sending MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws -> sending MLXArray {
        MLXArray(try speak(text, voice: voice, parameters: generationParameters))
    }

    func generateStream(
        text: String,
        voice: String?,
        refAudio: sending MLXArray?,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) -> sending AsyncThrowingStream<AudioGeneration, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioGeneration, Error>.makeStream()
        let task = Task {
            do {
                let samples = try self.speak(text, voice: voice, parameters: generationParameters)
                continuation.yield(.audio(MLXArray(samples)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func speak(
        _ text: String,
        voice: String?,
        parameters: GenerateParameters
    ) throws -> [Float] {
        let voiceName = voice?.lowercased() ?? Self.defaultVoice
        guard let speaker = voices[voiceName] else {
            throw WoofModelError.unknownVoice(voice ?? voiceName)
        }
        let random = parameters.seed.map { MLXRandom.RandomState(seed: $0) }
            ?? MLXRandom.RandomState()
        let utterances = try Self.sentenceChunker.chunks(
            for: normalizer.normalize(text),
            checkingCancellation: Task.checkCancellation
        ) {
            $0.count <= Self.utteranceCharacterLimit
        }
        // Woof cannot end an utterance with no English letters to read.
        return try utterances.filter {
            $0.text.contains { $0.isASCII && $0.isLetter }
        }.flatMap {
            try bestTake(
                of: $0.text,
                speaker: speaker,
                temperature: parameters.temperature,
                random: random
            )
        }
    }

    private func bestTake(
        of text: String,
        speaker: MLXArray,
        temperature: Float,
        random: MLXRandom.RandomState
    ) throws -> [Float] {
        let tokens = WoofSpeechModel.tokens(for: text)
        let frameLimit = min(
            maximumFrames,
            WoofTakeQuality.frameLimit(characterCount: text.count)
        )
        var best: (quality: WoofTakeQuality, samples: [Float])?
        for _ in 0...Self.retakeLimit {
            let generation = try speech.generate(
                voice: speaker,
                tokens: tokens,
                maximumFrames: frameLimit,
                temperature: temperature
            ) {
                MLXRandom.normal([1, speech.latentWidth], key: random)
            }
            let samples = decoder(generation.latents * latentDeviation + latentMean)
                .asArray(Float.self)
            try Task.checkCancellation()
            let quality = WoofTakeQuality(
                samples: samples,
                sampleRate: sampleRate,
                characterCount: text.count,
                reachedEnd: generation.reachedEnd
            )
            if best.map({ quality < $0.quality }) ?? true {
                best = (quality, samples)
            }
            if quality.isAcceptable { break }
        }
        return best?.samples ?? []
    }
}
