import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXAudioTTS
import MLXNN

/// Runs `PocketTTSModel` (used by both Gradium Phonon and Pocket TTS) with
/// `PocketTTSSentenceSplitter` so synthesis never breaks mid-sentence on
/// SentencePiece metaspace tokens.
///
/// Optimized execution path:
/// - Caches voice directory scans and prefilled FlowLM voice KV-cache snapshots
///   across chunks and consecutive requests.
/// - Uses `MLXFast.RoPE`, unmasked decode SDPA (`t == 1`), precomputed flow
///   time embeddings, single-pass `cond_embed`, and compiled `flow_net`.
/// - Pipelines FlowLM 1 step ahead with `asyncEval` so the GPU never stalls on
///   per-step EOS checks.
/// - Batches Mimi `decodeStep` across multiple latent frames per flush instead
///   of synchronizing and launching the full codec graph per 80 ms frame.
enum PocketTTSStreamRunner {
    private static let defaultAudioPrompt = "alba"
    private static let maxCachedVoiceStates = 4
    private static let cacheLock = NSLock()

    private struct VoiceStateCacheKey: Hashable {
        let modelID: ObjectIdentifier
        let voiceKey: String
        let referenceAudioID: ObjectIdentifier?
    }

    private struct CachedVoiceState {
        let layerStates: [(keys: MLXArray, values: MLXArray)]
        let promptNumFrames: Int
    }

    private struct CompiledModelState {
        let conditioningEmbedding: MLXArray?
        let useExactGELU: Bool
        let lsdDecodeSteps: Int
        let compiledFlowDecode: @Sendable (MLXArray, MLXArray) -> MLXArray
    }

    private final class CacheStore: @unchecked Sendable {
        var voiceFilesByFolder: [URL: [String: URL]] = [:]
        var voiceStates: [VoiceStateCacheKey: CachedVoiceState] = [:]
        var voiceStateOrder: [VoiceStateCacheKey] = []
        var compiledStates: [ObjectIdentifier: CompiledModelState] = [:]
    }

    private static let cacheStore = CacheStore()

    static func clearCaches(for model: PocketTTSModel? = nil) {
        cacheLock.withLock {
            if let model {
                let modelID = ObjectIdentifier(model)
                cacheStore.compiledStates.removeValue(forKey: modelID)
                cacheStore.voiceStateOrder.removeAll { key in
                    if key.modelID == modelID {
                        cacheStore.voiceStates.removeValue(forKey: key)
                        return true
                    }
                    return false
                }
            } else {
                cacheStore.voiceFilesByFolder.removeAll(keepingCapacity: false)
                cacheStore.voiceStates.removeAll(keepingCapacity: false)
                cacheStore.voiceStateOrder.removeAll(keepingCapacity: false)
                cacheStore.compiledStates.removeAll(keepingCapacity: false)
            }
        }
    }

    static func warmVoice(
        model: PocketTTSModel,
        modelFolder: URL,
        voice: String?,
        referenceAudio: MLXArray?
    ) throws {
        _ = compiledModelState(for: model)
        _ = try cachedVoiceState(
            model: model,
            modelFolder: modelFolder,
            voice: voice,
            referenceAudio: referenceAudio
        )
    }

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
        if let seed = generationParameters.seed {
            MLXRandom.seed(seed)
        }

        try validateSampling(model)
        let compiled = compiledModelState(for: model)
        let voiceState = try cachedVoiceState(
            model: model,
            modelFolder: modelFolder,
            voice: voice,
            referenceAudio: referenceAudio
        )

        let chunks = try PocketTTSSentenceSplitter.split(
            text,
            tokenizer: model.flow_lm.conditioner.tokenizer
        )
        let frameRate = max(model.mimi.frameRate, 1)
        let initialBatchFrames = max(
            1,
            Int((max(0, streamingInterval) * frameRate).rounded(.up))
        )
        let steadyBatchFrames = max(
            initialBatchFrames,
            streamingInterval >= 1.5 ? 24 : 12
        )
        var emittedFlushes = 0

        for chunk in chunks {
            try Task.checkCancellation()
            var state = makeState(from: voiceState, model: model)
            let (preparedChunk, guess) = try PocketTTSSentenceSplitter.prepareTextPrompt(chunk)
            let framesAfterEos = guess + 2
            try generateShortText(
                model: model,
                compiled: compiled,
                state: &state,
                text: preparedChunk,
                framesAfterEos: framesAfterEos,
                maxFrames: generationParameters.maxTokens,
                initialBatchFrames: initialBatchFrames,
                steadyBatchFrames: steadyBatchFrames,
                emittedFlushes: &emittedFlushes,
                onSamples: onSamples
            )
        }
    }

    private static func generateShortText(
        model: PocketTTSModel,
        compiled: CompiledModelState,
        state: inout PocketTTSState,
        text: String,
        framesAfterEos: Int,
        maxFrames: Int?,
        initialBatchFrames: Int,
        steadyBatchFrames: Int,
        emittedFlushes: inout Int,
        onSamples: ([Float]) -> Void
    ) throws {
        model.mimi.resetState()

        let words = text.split(separator: " ").count
        let genLenSec = Double(words) * 1.0 + 2.0
        let computedMax = Int(genLenSec * model.mimi.frameRate)
        let maxGenLen = max(0, maxFrames.map { min($0, computedMax) } ?? computedMax)
        guard maxGenLen > 0 else { return }

        let prepared = model.flow_lm.conditioner.prepare(text)
        if prepared.tokens.shape[1] > 0 {
            let textEmbeddings = model.flow_lm.conditioner(prepared)
            _ = runTransformer(
                model.flow_lm.transformer,
                input: textEmbeddings.asType(.float32),
                cache: state.flowCache,
                useExactGELU: compiled.useExactGELU
            )
        }
        // Match the upstream RNG sequence after prefill.
        _ = MLXRandom.normal([1, model.flow_lm.ldim])

        let bosInput = model.flow_lm.bos_emb.reshaped([1, 1, model.flow_lm.ldim])
        let embStd = model.flow_lm.emb_std
        let embMean = model.flow_lm.emb_mean
        let noiseScale = Float(sqrt(model.temp))
        let noiseClamp = model.noise_clamp
        let eosThreshold = model.eos_threshold

        var pendingLatents: [MLXArray] = []
        pendingLatents.reserveCapacity(steadyBatchFrames)

        func targetBatchFrames() -> Int {
            // Keep the first two deliveries tight for instant playback startup,
            // then decode larger batches to amortize Mimi Metal launches.
            emittedFlushes < 2 ? initialBatchFrames : steadyBatchFrames
        }

        func flushLatents() {
            guard !pendingLatents.isEmpty else { return }
            let latents = pendingLatents.count == 1
                ? pendingLatents[0]
                : concatenated(pendingLatents, axis: 1)
            pendingLatents.removeAll(keepingCapacity: true)
            let decodingInput = latents * embStd + embMean
            let quantized = model.mimi.quantizer(decodingInput.transposed(0, 2, 1))
            let audioChunk = model.mimi.decodeStep(quantized)
            let audio = audioChunk[0, 0].asType(.float32)
            eval(audio)
            let samples = audio.asArray(Float.self)
            if !samples.isEmpty {
                emittedFlushes += 1
                onSamples(samples)
            }
        }

        func enqueueStep(_ input: MLXArray) -> (latent: MLXArray, isEos: MLXArray) {
            let (out, isEos) = fastFlowStep(
                model: model,
                compiled: compiled,
                sequence: input,
                cache: state.flowCache,
                noiseScale: noiseScale,
                noiseClamp: noiseClamp,
                eosThreshold: eosThreshold
            )
            let nextLatent = out.expandedDimensions(axis: 1)
            asyncEval(nextLatent, isEos)
            return (nextLatent, isEos)
        }

        var eosStep: Int?
        var pending = enqueueStep(bosInput)

        for step in 0..<maxGenLen {
            try Task.checkCancellation()
            let current = pending

            // Queue the next FlowLM step BEFORE reading `current.isEos` so the
            // GPU stays busy during host-side EOS inspection. When `eosStep` is
            // nil, `framesAfterEos >= 3` guarantees step + 1 is always needed.
            let stopStep = eosStep.map { $0 + framesAfterEos }
            let shouldPrefetchNext: Bool
            if let stopStep {
                shouldPrefetchNext = (step + 1) < min(maxGenLen, stopStep)
            } else {
                shouldPrefetchNext = (step + 1) < maxGenLen
            }
            if shouldPrefetchNext {
                pending = enqueueStep(current.latent)
            }

            if eosStep == nil {
                if current.isEos.item(Bool.self) {
                    eosStep = step
                }
            }
            if let eosStep, step >= eosStep + framesAfterEos {
                break
            }

            pendingLatents.append(current.latent)
            if pendingLatents.count >= targetBatchFrames() {
                flushLatents()
            }
        }

        try Task.checkCancellation()
        flushLatents()
    }

    // MARK: - Fast FlowLM Execution

    private static func compiledModelState(
        for model: PocketTTSModel
    ) -> CompiledModelState {
        let modelID = ObjectIdentifier(model)
        let steps = model.lsd_decode_steps
        if let cached = cacheLock.withLock({ cacheStore.compiledStates[modelID] }),
           cached.lsdDecodeSteps == steps {
            return cached
        }

        var conditioningEmbedding = model.flow_lm.num_speakers?(MLXArray([Int32(1)]))
        if let duration = model.flow_lm.duration_delta?(MLXArray([Float(0)])) {
            conditioningEmbedding = conditioningEmbedding.map { $0 + duration } ?? duration
        }
        if let conditioningEmbedding {
            eval(conditioningEmbedding)
        }

        let flowNet = model.flow_lm.flow_net
        let numTimeConds = Float(flowNet.num_time_conds)
        var precomputedTimeConds: [MLXArray] = []
        precomputedTimeConds.reserveCapacity(steps)
        for i in 0..<steps {
            let s = Float(i) / Float(steps)
            let t = Float(i + 1) / Float(steps)
            let sT = MLXArray([s]).reshaped([1, 1])
            let tT = MLXArray([t]).reshaped([1, 1])
            let ts = [sT, tT]
            var tCombined = MLXArray.zeros([1, flowNet.model_channels])
            for (idx, embed) in flowNet.time_embed.enumerated() {
                tCombined = tCombined + embed(ts[idx])
            }
            tCombined = tCombined / MLXArray(numTimeConds)
            eval(tCombined)
            precomputedTimeConds.append(tCombined)
        }

        let invSteps = Float(1.0) / Float(steps)
        let timeConds = precomputedTimeConds
        let compiledFlowDecode = compile(
            inputs: [flowNet],
            outputs: [],
            shapeless: false
        ) { (condition: MLXArray, x0: MLXArray) -> MLXArray in
            let cc = flowNet.cond_embed(condition)
            var current = x0
            for tCombined in timeConds {
                let y = tCombined + cc
                var xx = flowNet.input_proj(current)
                for block in flowNet.res_blocks {
                    xx = block(xx, y)
                }
                let flowDir = flowNet.final_layer(xx, y)
                current = current + flowDir * invSteps
            }
            return current
        }

        let state = CompiledModelState(
            conditioningEmbedding: conditioningEmbedding,
            useExactGELU: model.config.flowLM.transformer.gelu == "erf",
            lsdDecodeSteps: steps,
            compiledFlowDecode: compiledFlowDecode
        )
        cacheLock.withLock {
            cacheStore.compiledStates[modelID] = state
        }
        return state
    }

    private static func fastFlowStep(
        model: PocketTTSModel,
        compiled: CompiledModelState,
        sequence: MLXArray,
        cache: [KVCacheSimple],
        noiseScale: Float,
        noiseClamp: Float?,
        eosThreshold: Float
    ) -> (MLXArray, MLXArray) {
        var input = model.flow_lm.input_linear(sequence)
        if let cond = compiled.conditioningEmbedding {
            input = input + cond
        }
        var transformerOut = runTransformer(
            model.flow_lm.transformer,
            input: input,
            cache: cache,
            useExactGELU: compiled.useExactGELU
        )
        transformerOut = model.flow_lm.out_norm(transformerOut).asType(.float32)

        let lastToken = transformerOut[0..., (transformerOut.shape[1] - 1)..., 0...]
            .squeezed(axis: 1)
        let eosLogits = model.flow_lm.out_eos(lastToken)
        let isEos = eosLogits[0, 0] .> eosThreshold

        var noise = MLXRandom.normal([lastToken.shape[0], model.flow_lm.ldim]) * noiseScale
        if let noiseClamp {
            noise = MLX.clip(noise, min: -noiseClamp, max: noiseClamp)
        }
        let nextLatent = compiled.compiledFlowDecode(lastToken, noise)
        return (nextLatent, isEos)
    }

    private static func runTransformer(
        _ transformer: PocketStreamingTransformer,
        input: MLXArray,
        cache: [KVCacheSimple],
        useExactGELU: Bool
    ) -> MLXArray {
        var h = input
        for (layer, layerCache) in zip(transformer.layers, cache) {
            let attnOut = fastAttention(layer.self_attn, query: layer.norm1(h), cache: layerCache)
            if let scale1 = layer.layer_scale_1 {
                h = h + scale1(attnOut)
            } else {
                h = h + attnOut
            }
            let hidden = layer.linear1(layer.norm2(h))
            let ff = layer.linear2(useExactGELU ? gelu(hidden) : geluApproximate(hidden))
            if let scale2 = layer.layer_scale_2 {
                h = h + scale2(ff)
            } else {
                h = h + ff
            }
        }
        return h
    }

    @inline(__always)
    private static func fastAttention(
        _ attn: PocketStreamingMultiheadAttention,
        query: MLXArray,
        cache: KVCacheSimple
    ) -> MLXArray {
        let b = query.shape[0]
        let t = query.shape[1]
        let numHeads = attn.numHeads
        let headDim = attn.headDim

        let projected = attn.in_proj(query).reshaped([b, t, 3, numHeads, headDim])
        var q = swappedAxes(projected[0..., 0..., 0, 0..., 0...], 1, 2)
        var k = swappedAxes(projected[0..., 0..., 1, 0..., 0...], 1, 2)
        let v = swappedAxes(projected[0..., 0..., 2, 0..., 0...], 1, 2)

        let offset = cache.offset
        let base = Float(attn.rope.maxPeriod)
        q = MLXFast.RoPE(q, dimensions: headDim, traditional: true, base: base, scale: 1.0, offset: offset)
        k = MLXFast.RoPE(k, dimensions: headDim, traditional: true, base: base, scale: 1.0, offset: offset)

        let (kFull, vFull) = cache.update(keys: k, values: v)
        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = t == 1 ? .none : .causal
        let out = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: kFull,
            values: vFull,
            scale: attn.scale,
            mask: maskMode
        )
        let merged = swappedAxes(out, 1, 2).reshaped([b, t, attn.embedDim])
        return attn.out_proj(merged)
    }

    // MARK: - Voice Conditioning & KV-Cache Snapshots

    private static func cachedVoiceState(
        model: PocketTTSModel,
        modelFolder: URL,
        voice: String?,
        referenceAudio: MLXArray?
    ) throws -> CachedVoiceState {
        let key = VoiceStateCacheKey(
            modelID: ObjectIdentifier(model),
            voiceKey: referenceAudio == nil ? (voice ?? "").lowercased() : "",
            referenceAudioID: referenceAudio.map(ObjectIdentifier.init)
        )
        if let cached = cacheLock.withLock({ cacheStore.voiceStates[key] }) {
            return cached
        }

        let conditioning = try resolveConditioning(
            model: model,
            modelFolder: modelFolder,
            voice: voice,
            referenceAudio: referenceAudio
        )
        let compiled = compiledModelState(for: model)
        let state = try initialState(
            model: model,
            conditioning: conditioning,
            useExactGELU: compiled.useExactGELU
        )
        let promptNumFrames = flowCacheNumFrames(state)
        var layerStates: [(keys: MLXArray, values: MLXArray)] = []
        layerStates.reserveCapacity(state.flowCache.count)
        var arraysToEval: [MLXArray] = []
        arraysToEval.reserveCapacity(state.flowCache.count * 2)
        for cache in state.flowCache {
            let entries = cache.state
            guard entries.count == 2 else { continue }
            layerStates.append((entries[0], entries[1]))
            arraysToEval.append(entries[0])
            arraysToEval.append(entries[1])
        }
        if !arraysToEval.isEmpty {
            eval(arraysToEval)
        }
        let snapshot = CachedVoiceState(
            layerStates: layerStates,
            promptNumFrames: promptNumFrames
        )
        cacheLock.withLock {
            if cacheStore.voiceStates[key] == nil {
                cacheStore.voiceStateOrder.append(key)
                if cacheStore.voiceStateOrder.count > maxCachedVoiceStates {
                    let evicted = cacheStore.voiceStateOrder.removeFirst()
                    cacheStore.voiceStates.removeValue(forKey: evicted)
                }
            }
            cacheStore.voiceStates[key] = snapshot
        }
        return snapshot
    }

    private static func makeState(
        from cached: CachedVoiceState,
        model: PocketTTSModel
    ) -> PocketTTSState {
        let state = model.initState()
        for (cache, saved) in zip(state.flowCache, cached.layerStates) {
            cache.state = [saved.keys, saved.values]
            cache.offset = cached.promptNumFrames
        }
        return state
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
        if let cached = cacheLock.withLock({ cacheStore.voiceFilesByFolder[modelFolder] }) {
            return cached
        }
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
        cacheLock.withLock {
            cacheStore.voiceFilesByFolder[modelFolder] = voices
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
        conditioning rawConditioning: MLXArray,
        useExactGELU: Bool
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
            _ = runTransformer(
                model.flow_lm.transformer,
                input: conditioning.asType(.float32),
                cache: state.flowCache,
                useExactGELU: useExactGELU
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
