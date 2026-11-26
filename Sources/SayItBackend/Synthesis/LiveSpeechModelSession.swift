import Foundation

@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon
import SayItCore

/// A loaded MLX speech model behind the adapter-neutral session port.
/// Instances are only accessed while the synthesis operation gate is held.
final class LiveSpeechModelSession: SpeechModelSession, @unchecked Sendable {
    private static let kokoroTokenBudget = 500

    let sampleRate: Double

    private let descriptor: ModelDescriptor
    private var model: SpeechGenerationModel?
    private var textProcessor: (any TextProcessor)?
    private var retainedReferenceAudio: MLXArray?
    private var retainedReferenceSamples: [Float]?
    private var retainedReferenceTranscript: String?

    init(
        descriptor: ModelDescriptor,
        model: SpeechGenerationModel,
        textProcessor: (any TextProcessor)?
    ) {
        sampleRate = Double(model.sampleRate)
        self.descriptor = descriptor
        self.model = model
        self.textProcessor = textProcessor
    }

    func generateSamples(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        allowTuningSelectedGeneration: Bool
    ) async throws -> [Float] {
        guard let model else {
            throw SynthesisError.generatedNoAudio
        }
        applyModelSpecificTuning(tuning, to: model)
        let referenceAudio = reference.map {
            SerializedMLXArray(referenceArray(for: $0))
        } ?? SerializedMLXArray(nil)
        do {
            if allowTuningSelectedGeneration,
               let omniVoice = model as? OmniVoiceModel,
               let tuning,
               tuning.parameters["diffusionSteps"] != nil {
                return try await SerializedSpeechModel(omniVoice)
                    .generateOmniVoiceSamples(
                        text: text,
                        voice: voice,
                        referenceAudio: referenceAudio,
                        refText: reference?.transcript,
                        language: language,
                        parameters: omniVoiceParameters(from: tuning)
                    )
            }
            return try await SerializedSpeechModel(model)
                .generateSamples(
                    text: text,
                    voice: voice,
                    referenceAudio: referenceAudio,
                    refText: reference?.transcript,
                    language: language,
                    generationParameters: generationParameters(
                        for: model,
                        tuning: tuning,
                        seed: seed
                    )
                )
        } catch {
            throw Self.classified(error)
        }
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) -> AsyncThrowingStream<[Float], Error> {
        guard let model else {
            return Self.failedStream(SynthesisError.generatedNoAudio)
        }
        // The diffusion-style generation path has no streaming form, so it
        // delivers its one-shot result as a single streamed buffer.
        if model is OmniVoiceModel,
           tuning?.parameters["diffusionSteps"] != nil {
            return Self.bridgedStream { continuation in
                do {
                    let samples = try await self.generateSamples(
                        text: text,
                        voice: voice,
                        reference: reference,
                        language: language,
                        tuning: tuning,
                        seed: seed,
                        allowTuningSelectedGeneration: true
                    )
                    continuation.yield(samples)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        applyModelSpecificTuning(tuning, to: model)
        let referenceAudio = reference.map {
            SerializedMLXArray(referenceArray(for: $0))
        } ?? SerializedMLXArray(nil)
        let underlying = SerializedSpeechModel(model)
            .generateSamplesStream(
                text: text,
                voice: voice,
                referenceAudio: referenceAudio,
                refText: reference?.transcript,
                language: language,
                generationParameters: generationParameters(
                    for: model,
                    tuning: tuning,
                    seed: seed
                ),
                streamingInterval: descriptor.playbackMode
                    == .progressive ? 0.32 : 2
            )
        return Self.bridgedStream { continuation in
            do {
                for try await samples in underlying {
                    continuation.yield(samples)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.classified(error))
            }
        }
    }

    func fittingPieces(
        for chunk: SpeechChunk,
        language: String?,
        voice: String?,
        chunker: TextChunker
    ) async throws -> [SpeechChunk] {
        guard let textProcessor, let model else { return [chunk] }
        switch descriptor.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            let language = language
                ?? voice.flatMap(
                    KokoroMultilingualProcessor.languageForVoice
                )
                ?? "en-us"
            if let processor =
                textProcessor as? KokoroMultilingualProcessor {
                try await processor.prepare(for: language)
            }
            return try chunker.fittingPieces(for: chunk) { text in
                try Task.checkCancellation()
                let processed = try textProcessor.process(
                    text: text,
                    language: language
                )
                return processed.unicodeScalars.count
                    <= Self.kokoroTokenBudget
            }
        case "kitten", "kitten_tts":
            let contextLength =
                (model as? KittenTTSModel)?
                    .config.plbert.maxPositionEmbeddings
                ?? 512
            let tokenBudget = max(contextLength - 2, 1)
            return try chunker.fittingPieces(for: chunk) { text in
                try Task.checkCancellation()
                let processed = try textProcessor.process(
                    text: text,
                    language: language
                )
                return processed.count <= tokenBudget
            }
        default:
            return [chunk]
        }
    }

    func applySpeakingPace(_ pace: SpeakingPace) throws {
        guard descriptor.supportsNativeSpeakingPace else { return }
        switch descriptor.modelType.lowercased() {
        case "kokoro", "kokoro_tts":
            guard let kokoro = model as? KokoroModel else {
                throw SynthesisError.speakingPaceUnavailable
            }
            kokoro.speed = Float(pace.rawValue)
        default:
            break
        }
    }

    func quiesce() {
        guard model != nil || retainedReferenceAudio != nil else { return }
        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    func shutdown() {
        guard model != nil || retainedReferenceAudio != nil else {
            textProcessor = nil
            retainedReferenceSamples = nil
            retainedReferenceTranscript = nil
            return
        }
        Stream.gpu.synchronize()
        model = nil
        textProcessor = nil
        retainedReferenceAudio = nil
        retainedReferenceSamples = nil
        retainedReferenceTranscript = nil
        Memory.clearCache()
    }

    /// The one tuning-to-generation-parameter translation. Model-specific
    /// overrides and the diffusion-style path are applied per generation
    /// call from the same uninterpreted tuning.
    private func generationParameters(
        for model: SpeechGenerationModel,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) -> GenerateParameters {
        var parameters = model.defaultGenerationParameters
        if let tuning {
            if let value = tuning.parameters["temperature"] {
                parameters.temperature = Float(value)
            }
            if let value = tuning.parameters["topP"] {
                parameters.topP = Float(value)
            }
            if let value = tuning.parameters["topK"] {
                parameters.topK = Int(value.rounded())
            }
            if let value = tuning.parameters["repetitionPenalty"] {
                parameters.repetitionPenalty = Float(value)
            }
        }
        if let seed {
            parameters.seed = seed
        }
        return parameters
    }

    private func applyModelSpecificTuning(
        _ tuning: VoiceSynthesisTuning?,
        to model: SpeechGenerationModel
    ) {
        guard let chatterbox = model as? ChatterboxModel else { return }
        chatterbox.cfgWeightOverride = tuning?.parameters["cfg"].map(Float.init)
        chatterbox.emotionAdvOverride =
            tuning?.parameters["exaggeration"].map(Float.init)
    }

    private func omniVoiceParameters(
        from tuning: VoiceSynthesisTuning
    ) -> OmniVoiceGenerateParameters {
        OmniVoiceGenerateParameters(
            numStep: Int(
                (tuning.parameters["diffusionSteps"] ?? 32).rounded()
            ),
            guidanceScale: Float(tuning.parameters["guidance"] ?? 2),
            tShift: Float(tuning.parameters["timeShift"] ?? 0.1),
            positionTemperature: Float(
                tuning.parameters["positionTemperature"] ?? 5
            ),
            classTemperature: Float(
                tuning.parameters["classTemperature"] ?? 0
            )
        )
    }

    // Retain each reference array until the next one is allocated: the
    // pinned Qwen3 wrapper caches reference conditioning by the array's
    // ObjectIdentifier without retaining it, so a freed address reused by
    // the next array would falsely hit that cache and replay stale audio.
    // A reference with identical samples and transcript reuses the
    // retained array, so conditioning for one reference keeps a stable
    // identity across generation calls without ever replaying
    // conditioning captured for a different transcript.
    private func referenceArray(
        for reference: SpeechModelReference
    ) -> MLXArray {
        if let retainedReferenceAudio,
           retainedReferenceSamples == reference.samples,
           retainedReferenceTranscript == reference.transcript {
            return retainedReferenceAudio
        }
        let array = MLXArray(reference.samples)
        retainedReferenceAudio = array
        retainedReferenceSamples = reference.samples
        retainedReferenceTranscript = reference.transcript
        return array
    }

    private static func bridgedStream(
        _ operation: @escaping @Sendable (
            AsyncThrowingStream<[Float], Error>.Continuation
        ) async -> Void
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await operation(continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func failedStream(
        _ error: Error
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    private static func classified(_ error: Error) -> Error {
        isInputLengthError(error)
            ? SpeechModelInputTooLongError(underlyingError: error)
            : error
    }

    private static func isInputLengthError(_ error: Error) -> Bool {
        let message: String
        if case .invalidInput(let detail) = error as? AudioGenerationError {
            message = detail
        } else {
            message = error.localizedDescription
        }
        let normalized = message.lowercased()
        return [
            "input too long",
            "inputs too long",
            "text token count",
            "max_text_tokens",
            "maximum context",
            "context length",
            "sequence length"
        ].contains { normalized.contains($0) }
    }
}

/// MLX Audio's public model protocol is not concurrency annotated. Instances
/// are only accessed while the synthesis operation gate is held, and this
/// adapter prevents the non-Sendable model and arrays from escaping that
/// critical section. Callers only receive materialized, Sendable sample
/// buffers.
private final class SerializedSpeechModel: @unchecked Sendable {
    private let model: SpeechGenerationModel

    init(_ model: SpeechGenerationModel) {
        self.model = model
    }

    func generateSamples(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            generationParameters: generationParameters
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        try Task.checkCancellation()
        return samples
    }

    func generateOmniVoiceSamples(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        parameters: OmniVoiceGenerateParameters
    ) async throws -> [Float] {
        guard let model = model as? OmniVoiceModel else {
            throw SynthesisError.generatedNoAudio
        }
        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            ovParameters: parameters
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        try Task.checkCancellation()
        return samples
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        referenceAudio: SerializedMLXArray,
        refText: String?,
        language: String?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<[Float], Error> {
        model.generateSamplesStream(
            text: text,
            voice: voice,
            refAudio: referenceAudio.value,
            refText: refText,
            language: language,
            generationParameters: generationParameters,
            streamingInterval: streamingInterval
        )
    }
}

/// See `SerializedSpeechModel`: this value never leaves the globally
/// serialized MLX operation.
private struct SerializedMLXArray: @unchecked Sendable {
    let value: MLXArray?

    init(_ value: MLXArray?) {
        self.value = value
    }
}
