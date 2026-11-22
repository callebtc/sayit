import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS

/// Runs `PocketTTSModel` (used by both Gradium Phonon and Pocket TTS) with
/// `PocketTTSSentenceSplitter` so synthesis never breaks mid-sentence on
/// SentencePiece metaspace tokens.
enum PocketTTSStreamRunner {
    private static let defaultAudioPrompt = "alba"

    static func generateSamples(
        model: PocketTTSModel,
        modelFolder: URL,
        text: String,
        voice: String?,
        referenceAudio: MLXArray?,
        generationParameters: GenerateParameters
    ) throws -> [Float] {
        var output: [Float] = []
        try run(
            model: model,
            modelFolder: modelFolder,
            text: text,
            voice: voice,
            referenceAudio: referenceAudio,
            generationParameters: generationParameters,
            streamingInterval: 2.0
        ) { samples in
            output.append(contentsOf: samples)
        }
        return output
    }

    static func generateSamplesStream(
        model: PocketTTSModel,
        modelFolder: URL,
        text: String,
        voice: String?,
        referenceAudio: MLXArray?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let box = RunnerInputs(
            model: model,
            modelFolder: modelFolder,
            text: text,
            voice: voice,
            referenceAudio: referenceAudio,
            generationParameters: generationParameters,
            streamingInterval: streamingInterval
        )
        let task = Task {
            do {
                try run(
                    model: box.model,
                    modelFolder: box.modelFolder,
                    text: box.text,
                    voice: box.voice,
                    referenceAudio: box.referenceAudio,
                    generationParameters: box.generationParameters,
                    streamingInterval: box.streamingInterval
                ) { samples in
                    continuation.yield(samples)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    private static func run(
        model: PocketTTSModel,
        modelFolder: URL,
        text: String,
        voice: String?,
        referenceAudio: MLXArray?,
        generationParameters: GenerateParameters,
        streamingInterval: Double,
        onSamples: ([Float]) -> Void
    ) throws {
        guard streamingInterval.isFinite else {
            throw runnerError("Streaming interval must be finite")
        }
        let previousTemperature = model.temp
        model.temp = generationParameters.temperature
        defer { model.temp = previousTemperature }

        try validateSampling(model)
        let conditioning = try resolveConditioning(
            model: model,
            modelFolder: modelFolder,
            voice: voice,
            referenceAudio: referenceAudio
        )
        var state = try initialState(model: model, conditioning: conditioning)
        let promptNumFrames = flowCacheNumFrames(state)

        let chunks = try PocketTTSSentenceSplitter.split(
            text,
            tokenizer: model.flow_lm.conditioner.tokenizer
        )
        let intervalSamples = max(
            1,
            Int(max(0, streamingInterval) * Double(model.sampleRate))
        )
        var buffer: [MLXArray] = []
        var bufferedSamples = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let audio = buffer.count == 1 ? buffer[0] : concatenated(buffer, axis: 0)
            buffer.removeAll(keepingCapacity: true)
            bufferedSamples = 0
            eval(audio)
            let samples = audio.asType(.float32).asArray(Float.self)
            if !samples.isEmpty {
                onSamples(samples)
            }
        }

        for chunk in chunks {
            try Task.checkCancellation()
            sliceFlowCache(&state, to: promptNumFrames)
            let (preparedChunk, guess) = try PocketTTSSentenceSplitter.prepareTextPrompt(chunk)
            let framesAfterEos = guess + 2
            try generateShortText(
                model: model,
                state: &state,
                text: preparedChunk,
                framesAfterEos: framesAfterEos,
                maxFrames: generationParameters.maxTokens
            ) { frame in
                buffer.append(frame)
                bufferedSamples += frame.size
                if bufferedSamples >= intervalSamples {
                    flush()
                }
            }
        }
        flush()
    }

    private static func generateShortText(
        model: PocketTTSModel,
        state: inout PocketTTSState,
        text: String,
        framesAfterEos: Int,
        maxFrames: Int?,
        onFrame: (MLXArray) -> Void
    ) throws {
        model.mimi.resetState()

        let words = text.split(separator: " ").count
        let genLenSec = Double(words) * 1.0 + 2.0
        let computedMax = Int(genLenSec * model.mimi.frameRate)
        let maxGenLen = max(0, maxFrames.map { min($0, computedMax) } ?? computedMax)

        let prepared = model.flow_lm.conditioner.prepare(text)
        if prepared.tokens.shape[1] > 0 {
            let textEmbeddings = model.flow_lm.conditioner(prepared)
            _ = model.flow_lm.transformer(
                textEmbeddings.asType(.float32),
                cache: state.flowCache
            )
        }
        // Match the upstream RNG sequence after prefill.
        _ = MLXRandom.normal([1, model.flow_lm.ldim])

        var backboneInput = MLXArray.ones([1, 1, model.flow_lm.ldim]) * MLXArray(Float.nan)
        let emptyTextEmbeddings = MLXArray.zeros([1, 0, model.flow_lm.dim])
        var eosStep: Int?

        for step in 0..<maxGenLen {
            try Task.checkCancellation()
            let (out, isEos) = model.flow_lm(
                sequence: backboneInput,
                textEmbeddings: emptyTextEmbeddings,
                cache: state.flowCache,
                lsdDecodeSteps: model.lsd_decode_steps,
                temperature: model.temp,
                noiseClamp: model.noise_clamp,
                eosThreshold: model.eos_threshold
            )
            try Task.checkCancellation()
            let nextLatent = out.expandedDimensions(axis: 1)

            if eosStep == nil {
                let eos = isEos.asArray(Bool.self).first ?? false
                if eos { eosStep = step }
            }
            if let eosStep, step >= eosStep + framesAfterEos {
                break
            }

            let decodingInput = nextLatent * model.flow_lm.emb_std + model.flow_lm.emb_mean
            let quantized = model.mimi.quantizer(decodingInput.transposed(0, 2, 1))
            let audioChunk = model.mimi.decodeStep(quantized)
            let frame = audioChunk[0, 0]
            eval(frame)
            onFrame(frame)
            backboneInput = nextLatent
        }

        try Task.checkCancellation()
    }

    private static func validateSampling(_ model: PocketTTSModel) throws {
        guard model.lsd_decode_steps > 0,
              model.temp.isFinite,
              model.temp >= 0,
              model.noise_clamp.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw runnerError(
                "Sampling requires positive lsd_decode_steps and finite, nonnegative temperature and noise_clamp"
            )
        }
    }

    private static func resolveConditioning(
        model: PocketTTSModel,
        modelFolder: URL,
        voice: String?,
        referenceAudio: MLXArray?
    ) throws -> MLXArray {
        if let referenceAudio {
            guard model.mimi.encoder != nil else {
                throw runnerError(
                    "This checkpoint omits the speaker encoder; use a bundled voice embedding"
                )
            }
            var audio = normalizeAudio(referenceAudio)
            guard audio.ndim == 3,
                  audio.shape[0] == 1,
                  audio.shape[1] == model.config.mimi.channels else {
                throw runnerError(
                    "Audio prompt must have shape [1, \(model.config.mimi.channels), T]"
                )
            }
            let minSamples = model.config.audioPromptMinDuration * Double(model.sampleRate)
            guard Double(audio.shape[2]) >= minSamples else {
                throw runnerError(
                    "Audio prompt must be at least \(model.config.audioPromptMinDuration) seconds"
                )
            }
            if let maximum = model.config.audioPromptMaxDuration {
                let maxSamples = min(audio.shape[2], Int(maximum * Double(model.sampleRate)))
                audio = audio[.ellipsis, ..<maxSamples]
            }
            if audio.shape[2] == 0 {
                return MLXArray.zeros([1, 0, model.flow_lm.dim])
            }
            let encoded = model.mimi.encodeToLatent(audio.asType(.float32))
            let latents = encoded.transposed(0, 2, 1).asType(.float32)
            return matmul(latents, model.speaker_proj_weight.transposed(1, 0))
        }

        if let voice {
            let expanded = (voice as NSString).expandingTildeInPath
            let file = URL(fileURLWithPath: expanded)
            if file.pathExtension == "safetensors",
               FileManager.default.fileExists(atPath: file.path) {
                return try voiceConditioning(
                    MLX.loadArrays(url: file),
                    model: model
                )
            }
        }

        let voices = voiceFiles(in: modelFolder)
        let defaultVoice = ["default", defaultAudioPrompt].first { voices[$0] != nil }
        let selected = voice?.lowercased()
            ?? defaultVoice
            ?? voices.keys.sorted().first
            ?? defaultAudioPrompt
        guard let file = voices[selected] else {
            let available = voices.keys.sorted().joined(separator: ", ")
            throw runnerError("Unknown voice '\(selected)'. Available voices: \(available)")
        }
        return try voiceConditioning(MLX.loadArrays(url: file), model: model)
    }

    private static func voiceFiles(in modelFolder: URL) -> [String: URL] {
        var voices: [String: URL] = [:]
        for directory in ["voices", "embeddings"] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: modelFolder.appendingPathComponent(directory),
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "safetensors" {
                voices[file.deletingPathExtension().lastPathComponent.lowercased()] = file
            }
        }
        let defaultVoice = modelFolder.appendingPathComponent("default-voice.safetensors")
        if voices["default"] == nil,
           FileManager.default.fileExists(atPath: defaultVoice.path) {
            voices["default"] = defaultVoice
        }
        return voices
    }

    private static func voiceConditioning(
        _ arrays: [String: MLXArray],
        model: PocketTTSModel
    ) throws -> MLXArray {
        if var latents = arrays["speaker_wavs"] {
            if latents.ndim == 2 {
                latents = latents.expandedDimensions(axis: 0)
            }
            guard latents.ndim == 3,
                  latents.shape[0] == 1,
                  latents.shape[1] == model.speaker_proj_weight.shape[1] else {
                throw runnerError(
                    "Speaker latents must have shape [1, \(model.speaker_proj_weight.shape[1]), T]"
                )
            }
            return matmul(
                latents.transposed(0, 2, 1).asType(.float32),
                model.speaker_proj_weight.T
            )
        }
        guard let embedding = arrays["emb"] ?? arrays["audio_prompt"] else {
            throw runnerError("Voice file must contain speaker_wavs, emb, or audio_prompt")
        }
        return embedding
    }

    private static func normalizeAudio(_ audio: MLXArray) -> MLXArray {
        if audio.ndim == 1 {
            return audio.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
        }
        if audio.ndim == 2 {
            var mono = audio
            if audio.shape[0] > 1 {
                mono = MLX.mean(audio, axis: 0, keepDims: true)
            }
            return mono.expandedDimensions(axis: 0)
        }
        return audio
    }

    private static func initialState(
        model: PocketTTSModel,
        conditioning rawConditioning: MLXArray
    ) throws -> PocketTTSState {
        var state = model.initState()
        var conditioning = rawConditioning
        if conditioning.ndim == 2 {
            conditioning = conditioning.expandedDimensions(axis: 0)
        }
        guard conditioning.ndim == 3,
              conditioning.shape[0] == 1,
              conditioning.shape[2] == model.flow_lm.dim else {
            throw runnerError(
                "Voice embedding must have shape [1, T, \(model.flow_lm.dim)]"
            )
        }
        if conditioning.shape[1] > 0 {
            _ = model.flow_lm.transformer(
                conditioning.asType(.float32),
                cache: state.flowCache
            )
            _ = MLXRandom.normal([1, model.flow_lm.ldim])
        }
        sliceFlowCache(&state, to: conditioning.shape[1])
        return state
    }

    private static func sliceFlowCache(_ state: inout PocketTTSState, to length: Int) {
        let targetLength = max(length, 0)
        for cache in state.flowCache {
            let entries = cache.state
            guard entries.count == 2 else { continue }
            let keys = entries[0]
            let values = entries[1]
            let end = min(targetLength, keys.shape[2])
            let slicedKeys = keys[.ellipsis, ..<end, 0...]
            let slicedValues = values[.ellipsis, ..<end, 0...]
            cache.state = [slicedKeys, slicedValues]
            cache.offset = min(cache.offset, end)
        }
    }

    private static func flowCacheNumFrames(_ state: PocketTTSState) -> Int {
        for cache in state.flowCache {
            let entries = cache.state
            guard entries.count == 2 else { continue }
            return min(cache.offset, entries[0].shape[2])
        }
        return 0
    }

    private static func runnerError(_ message: String) -> NSError {
        NSError(
            domain: "PocketTTSStreamRunner",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Only constructed inside `SynthesisOperationGate` to transfer the non-Sendable
/// MLX model and reference array into the streaming task without escaping.
private final class RunnerInputs: @unchecked Sendable {
    let model: PocketTTSModel
    let modelFolder: URL
    let text: String
    let voice: String?
    let referenceAudio: MLXArray?
    let generationParameters: GenerateParameters
    let streamingInterval: Double

    init(
        model: PocketTTSModel,
        modelFolder: URL,
        text: String,
        voice: String?,
        referenceAudio: MLXArray?,
        generationParameters: GenerateParameters,
        streamingInterval: Double
    ) {
        self.model = model
        self.modelFolder = modelFolder
        self.text = text
        self.voice = voice
        self.referenceAudio = referenceAudio
        self.generationParameters = generationParameters
        self.streamingInterval = streamingInterval
    }
}
