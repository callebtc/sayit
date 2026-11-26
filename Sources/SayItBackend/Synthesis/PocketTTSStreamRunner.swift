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
///   across chunks and consecutive requests in the model's native weight dtype.
/// - Compiles the entire single-token FlowLM step (input projection, all 6
///   transformer layers with dynamic-offset `MLXFast.RoPE`, static capacity-bucketed
///   KV caches + causal SDPA, output norm, EOS check, and all `lsd_decode_steps`
///   of `flow_net`) into static-shape `MLX.compile(shapeless: false)` graphs for
///   both 1-step (ultra-low TTFA opening flush) and fused 4-step (steady-state
///   throughput with 4x fewer graph dispatches and host-GPU EOS syncs).
/// - Replaces Mimi's dense `eye(512)` depthwise transposed-conv upsample with
///   exact broadcast-multiply overlap-add (512x fewer FLOPs, zero eye allocation).
/// - Uses a tight 2-frame opening Mimi flush for instant first audio, then ramps
///   to 32-frame steady batches overlapped asynchronously (`asyncEval`) with the
///   next FlowLM batch.
enum PocketTTSStreamRunner {
    private static let defaultAudioPrompt = "alba"
    private static let maxCachedVoiceStates = 4
    private static let preallocatedOffsetCount = 1_024
    private static let quadStepSize = 4
    private static let cacheLock = NSLock()

    private struct VoiceStateCacheKey: Hashable {
        let modelID: ObjectIdentifier
        let voiceKey: String
        let referenceAudioID: ObjectIdentifier?
    }

    private struct CachedVoiceState {
        let keys: [MLXArray]
        let values: [MLXArray]
        let promptNumFrames: Int
    }

    private struct DepthwiseUpsampleWeights {
        let stride: Int
        let wFirst: MLXArray   // [1, C, 1, stride]
        let wSecond: MLXArray  // [1, C, 1, stride]
    }

    private struct CompiledModelState {
        let flowDType: DType
        let mimiDType: DType
        let conditioningEmbedding: MLXArray?
        let useExactGELU: Bool
        let lsdDecodeSteps: Int
        let eosThreshold: Float
        let numLayers: Int
        let offsetArrays: [MLXArray]
        let timeConds: [MLXArray]
        let depthwiseUpsample: DepthwiseUpsampleWeights?
        var compiledStepsByCapacity: [Int: @Sendable ([MLXArray]) -> [MLXArray]]
        var compiledQuadStepsByCapacity: [Int: @Sendable ([MLXArray]) -> [MLXArray]]
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
        let compiled = compiledModelState(for: model)
        let voiceState = try cachedVoiceState(
            model: model,
            modelFolder: modelFolder,
            voice: voice,
            referenceAudio: referenceAudio
        )

        // Pre-trace both primary capacity buckets (320 and 512) for 1-step and
        // 4-step FlowLM plus the Mimi decoder shaders during background preload
        // so the very first user utterance pays zero JIT compile latency.
        let primaryCap = cacheCapacity(forTotalLength: voiceState.promptNumFrames + 1)
        let buckets = primaryCap == 320 ? [320, 512] : [primaryCap]
        let bos = model.flow_lm.bos_emb
            .reshaped([1, 1, model.flow_lm.ldim])
            .asType(compiled.flowDType)
        let zeroNoise1 = MLXArray.zeros([1, model.flow_lm.ldim], dtype: compiled.flowDType)
        let zeroNoise4 = MLXArray.zeros([quadStepSize, 1, model.flow_lm.ldim], dtype: compiled.flowDType)

        var sampleLatent: MLXArray?
        var sampleEos: MLXArray?

        for capacity in buckets {
            var paddedKeys = voiceState.keys
            var paddedValues = voiceState.values
            padKVCaches(keys: &paddedKeys, values: &paddedValues, toCapacity: capacity, dtype: compiled.flowDType)

            let stepFn = compiledFlowStep(for: model, state: compiled, capacity: capacity)
            let off0 = offsetScalar(voiceState.promptNumFrames, cached: compiled.offsetArrays)
            var singleInputs: [MLXArray] = []
            singleInputs.reserveCapacity(3 + compiled.numLayers * 2)
            singleInputs.append(bos)
            singleInputs.append(zeroNoise1)
            singleInputs.append(off0)
            for i in 0..<compiled.numLayers {
                singleInputs.append(paddedKeys[i])
                singleInputs.append(paddedValues[i])
            }
            let singleOut = stepFn(singleInputs)
            if sampleLatent == nil {
                sampleLatent = singleOut[0]
                sampleEos = singleOut[1]
            }

            if voiceState.promptNumFrames + quadStepSize <= capacity {
                let quadFn = compiledFlowStep4(for: model, state: compiled, capacity: capacity)
                var quadInputs: [MLXArray] = []
                quadInputs.reserveCapacity(2 + quadStepSize + compiled.numLayers * 2)
                quadInputs.append(bos)
                quadInputs.append(zeroNoise4)
                for sub in 0..<quadStepSize {
                    quadInputs.append(offsetScalar(voiceState.promptNumFrames + sub, cached: compiled.offsetArrays))
                }
                for i in 0..<compiled.numLayers {
                    quadInputs.append(paddedKeys[i])
                    quadInputs.append(paddedValues[i])
                }
                let quadOut = quadFn(quadInputs)
                eval(singleOut[0], quadOut[0], quadOut[1])
            } else {
                eval(singleOut[0], singleOut[1])
            }
        }

        if let latent = sampleLatent, let eos = sampleEos {
            model.mimi.resetState()
            var upsamplePrev: MLXArray?
            let pairLatents = concatenated([latent, latent], axis: 1)
            let embStd = model.flow_lm.emb_std.asType(compiled.mimiDType)
            let embMean = model.flow_lm.emb_mean.asType(compiled.mimiDType)
            let audio = decodeMimiChunk(
                latents: pairLatents,
                model: model,
                compiled: compiled,
                embStd: embStd,
                embMean: embMean,
                upsamplePrevInput: &upsamplePrev
            )
            eval(audio, eos)
            model.mimi.resetState()
        }
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
        let requestedInitial = max(
            1,
            Int((max(0, streamingInterval) * frameRate).rounded(.up))
        )
        // Use a tight 2-frame opening flush (160 ms audio, above the 150 ms
        // minimum sustainable playback buffer) for instant first audio, then
        // ramp quickly to 32-frame steady batches overlapped with FlowLM.
        let firstFlushFrames = streamingInterval >= 1.5
            ? requestedInitial
            : min(2, requestedInitial)
        let secondFlushFrames = streamingInterval >= 1.5
            ? requestedInitial
            : max(firstFlushFrames, 8)
        let steadyBatchFrames = max(secondFlushFrames, 32)
        var emittedFlushes = 0

        for chunk in chunks {
            try Task.checkCancellation()
            let (preparedChunk, guess) = try PocketTTSSentenceSplitter.prepareTextPrompt(chunk)
            let framesAfterEos = guess + 2
            try generateShortText(
                model: model,
                compiled: compiled,
                voiceState: voiceState,
                text: preparedChunk,
                framesAfterEos: framesAfterEos,
                maxFrames: generationParameters.maxTokens,
                firstFlushFrames: firstFlushFrames,
                secondFlushFrames: secondFlushFrames,
                steadyBatchFrames: steadyBatchFrames,
                emittedFlushes: &emittedFlushes,
                onSamples: onSamples
            )
        }
    }

    private static func generateShortText(
        model: PocketTTSModel,
        compiled: CompiledModelState,
        voiceState: CachedVoiceState,
        text: String,
        framesAfterEos: Int,
        maxFrames: Int?,
        firstFlushFrames: Int,
        secondFlushFrames: Int,
        steadyBatchFrames: Int,
        emittedFlushes: inout Int,
        onSamples: ([Float]) -> Void
    ) throws {
        model.mimi.resetState()
        var upsamplePrevInput: MLXArray?

        let words = text.split(separator: " ").count
        let genLenSec = Double(words) * 1.0 + 2.0
        let computedMax = Int(genLenSec * model.mimi.frameRate)
        let maxGenLen = max(0, maxFrames.map { min($0, computedMax) } ?? computedMax)
        guard maxGenLen > 0 else { return }

        var keys = voiceState.keys
        var values = voiceState.values
        var kvOffset = voiceState.promptNumFrames

        let prepared = model.flow_lm.conditioner.prepare(text)
        if prepared.tokens.shape[1] > 0 {
            let textEmbeddings = model.flow_lm.conditioner(prepared)
                .asType(compiled.flowDType)
            _ = runPrefillTransformer(
                model.flow_lm.transformer,
                input: textEmbeddings,
                keys: &keys,
                values: &values,
                offset: &kvOffset,
                computeDType: compiled.flowDType,
                useExactGELU: compiled.useExactGELU
            )
        }

        // Start in the smallest power-of-two bucket that fits the prompt (256
        // for most chunks, matching `warmVoice`'s pre-traced graph) and expand
        // mid-chunk only when generation exceeds it.
        var capacity = cacheCapacity(forTotalLength: kvOffset + 1)
        padKVCaches(keys: &keys, values: &values, toCapacity: capacity, dtype: compiled.flowDType)
        var stepFn = compiledFlowStep(for: model, state: compiled, capacity: capacity)
        var quadStepFn = compiledFlowStep4(for: model, state: compiled, capacity: capacity)

        // Pre-generate all step noise in a single GPU op instead of 3 ops/step.
        let noiseScale = Float(sqrt(model.temp))
        var allNoise = MLXRandom.normal([maxGenLen, 1, model.flow_lm.ldim]) * noiseScale
        if let noiseClamp = model.noise_clamp {
            allNoise = MLX.clip(allNoise, min: -noiseClamp, max: noiseClamp)
        }
        allNoise = allNoise.asType(compiled.flowDType)
        asyncEval(allNoise)

        let bosInput = model.flow_lm.bos_emb
            .reshaped([1, 1, model.flow_lm.ldim])
            .asType(compiled.flowDType)
        let embStd = model.flow_lm.emb_std.asType(compiled.mimiDType)
        let embMean = model.flow_lm.emb_mean.asType(compiled.mimiDType)
        let numLayers = compiled.numLayers

        var pendingLatents: [MLXArray] = []
        pendingLatents.reserveCapacity(steadyBatchFrames)
        var pendingFrameCount = 0
        var inFlightMimiAudio: MLXArray?

        func targetBatchFrames() -> Int {
            switch emittedFlushes {
            case 0: firstFlushFrames
            case 1: secondFlushFrames
            default: steadyBatchFrames
            }
        }

        func drainInFlightMimi() {
            guard let audio = inFlightMimiAudio else { return }
            inFlightMimiAudio = nil
            let samples = audio.asArray(Float.self)
            if !samples.isEmpty {
                emittedFlushes += 1
                onSamples(samples)
            }
        }

        func appendPending(_ latents: MLXArray, count: Int) {
            guard count > 0 else { return }
            pendingLatents.append(latents)
            pendingFrameCount += count
        }

        func flushLatents(synchronous: Bool) {
            guard pendingFrameCount > 0 else {
                if synchronous { drainInFlightMimi() }
                return
            }
            let latents = pendingLatents.count == 1
                ? pendingLatents[0]
                : concatenated(pendingLatents, axis: 1)
            pendingLatents.removeAll(keepingCapacity: true)
            pendingFrameCount = 0

            // Deliver any previously overlapped Mimi chunk before launching the next.
            drainInFlightMimi()

            let audio = decodeMimiChunk(
                latents: latents,
                model: model,
                compiled: compiled,
                embStd: embStd,
                embMean: embMean,
                upsamplePrevInput: &upsamplePrevInput
            )

            if synchronous {
                eval(audio)
                let samples = audio.asArray(Float.self)
                if !samples.isEmpty {
                    emittedFlushes += 1
                    onSamples(samples)
                }
            } else {
                asyncEval(audio)
                inFlightMimiAudio = audio
            }
        }

        func ensureCapacity(forAdditionalSteps count: Int) {
            if kvOffset + count > capacity {
                let nextCapacity = cacheCapacity(forTotalLength: kvOffset + max(128, count))
                padKVCaches(keys: &keys, values: &values, toCapacity: nextCapacity, dtype: compiled.flowDType)
                capacity = nextCapacity
                stepFn = compiledFlowStep(for: model, state: compiled, capacity: nextCapacity)
                quadStepFn = compiledFlowStep4(for: model, state: compiled, capacity: nextCapacity)
            }
        }

        var singleInputs = [MLXArray](repeating: bosInput, count: 3 + numLayers * 2)
        var quadInputs = [MLXArray](repeating: bosInput, count: 2 + quadStepSize + numLayers * 2)
        var lastLatent = bosInput
        var nextStepIndex = 0
        var eosStep: Int?

        func runSingleStep() -> (step: Int, latent: MLXArray, isEos: MLXArray) {
            ensureCapacity(forAdditionalSteps: 1)
            let stepIdx = nextStepIndex
            nextStepIndex += 1
            let noise = allNoise[stepIdx]
            let offsetArray = offsetScalar(kvOffset, cached: compiled.offsetArrays)
            kvOffset += 1

            singleInputs[0] = lastLatent
            singleInputs[1] = noise
            singleInputs[2] = offsetArray
            for i in 0..<numLayers {
                singleInputs[3 + i * 2] = keys[i]
                singleInputs[4 + i * 2] = values[i]
            }

            let outputs = stepFn(singleInputs)
            let latent = outputs[0]
            let isEos = outputs[1]
            for i in 0..<numLayers {
                keys[i] = outputs[2 + i * 2]
                values[i] = outputs[3 + i * 2]
            }
            lastLatent = latent
            asyncEval(outputs)
            return (stepIdx, latent, isEos)
        }

        func runQuadStep() -> (startStep: Int, latents: MLXArray, eosFlags: MLXArray) {
            ensureCapacity(forAdditionalSteps: quadStepSize)
            let startIdx = nextStepIndex
            nextStepIndex += quadStepSize
            let noise4 = allNoise[startIdx..<(startIdx + quadStepSize)]

            quadInputs[0] = lastLatent
            quadInputs[1] = noise4
            for sub in 0..<quadStepSize {
                quadInputs[2 + sub] = offsetScalar(kvOffset + sub, cached: compiled.offsetArrays)
            }
            kvOffset += quadStepSize
            for i in 0..<numLayers {
                quadInputs[2 + quadStepSize + i * 2] = keys[i]
                quadInputs[3 + quadStepSize + i * 2] = values[i]
            }

            let outputs = quadStepFn(quadInputs)
            let latents4 = outputs[0]
            let eos4 = outputs[1]
            for i in 0..<numLayers {
                keys[i] = outputs[2 + i * 2]
                values[i] = outputs[3 + i * 2]
            }
            lastLatent = latents4[0..., (quadStepSize - 1)..<quadStepSize, 0...]
            asyncEval(outputs)
            return (startIdx, latents4, eos4)
        }

        // Phase 1: Opening flush using 1-step compiled FlowLM (depth 1) for
        // minimum TTFA without waiting for extra lookahead frames.
        if emittedFlushes == 0 {
            var current = runSingleStep()
            while true {
                try Task.checkCancellation()
                let stopStep = eosStep.map { $0 + framesAfterEos } ?? maxGenLen
                let limitStep = min(maxGenLen, stopStep)

                var next: (step: Int, latent: MLXArray, isEos: MLXArray)?
                if pendingFrameCount + 1 < firstFlushFrames && nextStepIndex < limitStep {
                    next = runSingleStep()
                }

                if eosStep == nil, current.isEos.item(Bool.self) {
                    eosStep = current.step
                }
                if let eosStep, current.step >= eosStep + framesAfterEos {
                    break
                }

                appendPending(current.latent, count: 1)
                if pendingFrameCount >= firstFlushFrames {
                    flushLatents(synchronous: true)
                    if let next {
                        // Consume the already-queued next frame if any.
                        if eosStep == nil, next.isEos.item(Bool.self) {
                            eosStep = next.step
                        }
                        if eosStep == nil || next.step < eosStep! + framesAfterEos {
                            appendPending(next.latent, count: 1)
                        }
                    }
                    break
                }

                if let queued = next {
                    current = queued
                } else {
                    let updatedLimit = min(maxGenLen, eosStep.map { $0 + framesAfterEos } ?? maxGenLen)
                    guard nextStepIndex < updatedLimit else { break }
                    current = runSingleStep()
                }
            }
        }

        // Phase 2: Steady-state fused 4-step pipelined FlowLM (when framesAfterEos >= 3
        // so even an EOS on sub-step 0 produces zero wasted frames).
        if framesAfterEos >= quadStepSize - 1 && eosStep == nil && nextStepIndex + quadStepSize <= maxGenLen {
            var currentBlock = runQuadStep()
            while true {
                try Task.checkCancellation()
                let nextBlock: (startStep: Int, latents: MLXArray, eosFlags: MLXArray)? =
                    nextStepIndex + quadStepSize <= maxGenLen ? runQuadStep() : nil

                let eosBools = currentBlock.eosFlags.asArray(Bool.self)
                if let firstEosOffset = eosBools.firstIndex(of: true) {
                    let detectedEos = currentBlock.startStep + firstEosOffset
                    eosStep = detectedEos
                    let totalAllowed = min(maxGenLen, detectedEos + framesAfterEos)
                    let keepInCurrent = max(0, min(quadStepSize, totalAllowed - currentBlock.startStep))
                    if keepInCurrent == quadStepSize {
                        appendPending(currentBlock.latents, count: quadStepSize)
                    } else if keepInCurrent > 0 {
                        appendPending(currentBlock.latents[0..., 0..<keepInCurrent, 0...], count: keepInCurrent)
                    }

                    var consumedSteps = currentBlock.startStep + keepInCurrent
                    if let nextBlock, consumedSteps < totalAllowed {
                        let keepInNext = max(0, min(quadStepSize, totalAllowed - nextBlock.startStep))
                        if keepInNext == quadStepSize {
                            appendPending(nextBlock.latents, count: quadStepSize)
                        } else if keepInNext > 0 {
                            appendPending(nextBlock.latents[0..., 0..<keepInNext, 0...], count: keepInNext)
                        }
                        consumedSteps = nextBlock.startStep + keepInNext
                    }
                    if pendingFrameCount >= targetBatchFrames() {
                        flushLatents(synchronous: false)
                    }
                    // Finish any remaining post-EOS tail frames (only if framesAfterEos > 7).
                    while consumedSteps < totalAllowed && nextStepIndex < totalAllowed {
                        try Task.checkCancellation()
                        let tail = runSingleStep()
                        appendPending(tail.latent, count: 1)
                        consumedSteps += 1
                    }
                    break
                }

                appendPending(currentBlock.latents, count: quadStepSize)
                if pendingFrameCount >= targetBatchFrames() {
                    flushLatents(synchronous: false)
                }

                if let nextBlock {
                    currentBlock = nextBlock
                } else {
                    break
                }
            }
        }

        // Phase 3: Finish any remaining tail (< 4 frames before maxGenLen, or
        // chunks where EOS fired during Phase 1 or framesAfterEos < 3).
        let finalStop = min(maxGenLen, eosStep.map { $0 + framesAfterEos } ?? maxGenLen)
        if nextStepIndex < finalStop && (eosStep == nil || nextStepIndex < finalStop) {
            var current = runSingleStep()
            while true {
                try Task.checkCancellation()
                let stopStep = eosStep.map { $0 + framesAfterEos } ?? maxGenLen
                let limitStep = min(maxGenLen, stopStep)
                let next = nextStepIndex < limitStep ? runSingleStep() : nil

                if eosStep == nil, current.isEos.item(Bool.self) {
                    eosStep = current.step
                }
                if let eosStep, current.step >= eosStep + framesAfterEos {
                    break
                }
                appendPending(current.latent, count: 1)
                if pendingFrameCount >= targetBatchFrames() {
                    flushLatents(synchronous: false)
                }

                if let next {
                    current = next
                } else {
                    let updatedLimit = min(maxGenLen, eosStep.map { $0 + framesAfterEos } ?? maxGenLen)
                    guard nextStepIndex < updatedLimit else { break }
                    current = runSingleStep()
                }
            }
        }

        try Task.checkCancellation()
        flushLatents(synchronous: true)
    }

    // MARK: - Optimized Mimi Decode & Depthwise Upsample

    private static func decodeMimiChunk(
        latents: MLXArray,
        model: PocketTTSModel,
        compiled: CompiledModelState,
        embStd: MLXArray,
        embMean: MLXArray,
        upsamplePrevInput: inout MLXArray?
    ) -> MLXArray {
        let decodingInput = latents.asType(compiled.mimiDType) * embStd + embMean
        let quantized = model.mimi.quantizer(decodingInput.transposed(0, 2, 1))
        let upsampled: MLXArray
        if let dw = compiled.depthwiseUpsample {
            upsampled = fastDepthwiseUpsampleStep(
                quantized,
                weights: dw,
                prevInput: &upsamplePrevInput
            )
        } else if let upsample = model.mimi.upsample {
            upsampled = upsample.step(quantized)
        } else {
            upsampled = quantized
        }
        let transformed = model.mimi.decoder_transformer(upsampled, cache: model.mimi.decoderCache)[0]
        let audioChunk = model.mimi.decoder.step(transformed)
        return audioChunk[0, 0].asType(.float32)
    }

    /// Exact streaming replacement for `ConvTrUpsample1d.step` (`groups == C`,
    /// `ksize == 2 * stride`, `bias == nil`, causal overlap-add). Avoids the
    /// `[C, ksize, C]` dense `eye(C)` matrix expansion and dense transposed
    /// convolution in `MimiConvTransposed1d`.
    static func fastDepthwiseUpsampleStep(
        _ x: MLXArray,
        wFirst: MLXArray,
        wSecond: MLXArray,
        stride: Int,
        prevInput: inout MLXArray?
    ) -> MLXArray {
        let b = x.shape[0]
        let c = x.shape[1]
        let t = x.shape[2]
        guard t > 0 else { return MLXArray.zeros([b, c, 0], dtype: x.dtype) }

        let head = prevInput ?? MLXArray.zeros([b, c, 1], dtype: x.dtype)
        let xPrev: MLXArray
        if t == 1 {
            xPrev = head
        } else {
            xPrev = concatenated([head, x[0..., 0..., 0..<(t - 1)]], axis: 2)
        }
        prevInput = x[0..., 0..., (t - 1)...]

        let xCurrExp = x.expandedDimensions(axis: 3)
        let xPrevExp = xPrev.expandedDimensions(axis: 3)
        let out = xCurrExp * wFirst + xPrevExp * wSecond
        return out.reshaped([b, c, t * stride])
    }

    private static func fastDepthwiseUpsampleStep(
        _ x: MLXArray,
        weights: DepthwiseUpsampleWeights,
        prevInput: inout MLXArray?
    ) -> MLXArray {
        fastDepthwiseUpsampleStep(
            x,
            wFirst: weights.wFirst,
            wSecond: weights.wSecond,
            stride: weights.stride,
            prevInput: &prevInput
        )
    }

    private static func extractDepthwiseUpsampleWeights(
        from mimi: MimiAdapter,
        dtype: DType
    ) -> DepthwiseUpsampleWeights? {
        guard let upsample = mimi.upsample else { return nil }
        let convtr = upsample.convtr.convtr.convtr
        guard convtr.bias == nil, convtr.stride > 0 else { return nil }
        let s = convtr.stride
        let ksize = 2 * s
        let w = convtr.weight
        guard w.ndim == 3, w.shape[1] == ksize else { return nil }

        let w2D: MLXArray
        let channels: Int
        if w.shape[2] == 1 && convtr.groups == w.shape[0] {
            channels = w.shape[0]
            w2D = w.squeezed(axis: 2)
        } else if w.shape[0] == 1 && convtr.groups == w.shape[2] {
            channels = w.shape[2]
            w2D = w.squeezed(axis: 0).transposed(1, 0)
        } else {
            return nil
        }

        let wFirst = w2D[0..., 0..<s].asType(dtype).reshaped([1, channels, 1, s])
        let wSecond = w2D[0..., s..<ksize].asType(dtype).reshaped([1, channels, 1, s])
        eval(wFirst, wSecond)
        return DepthwiseUpsampleWeights(stride: s, wFirst: wFirst, wSecond: wSecond)
    }

    // MARK: - Compiled Full-Step & Quad-Step FlowLM Execution

    private static func compiledModelState(
        for model: PocketTTSModel
    ) -> CompiledModelState {
        let modelID = ObjectIdentifier(model)
        let steps = model.lsd_decode_steps
        let eosThreshold = model.eos_threshold
        if let cached = cacheLock.withLock({ cacheStore.compiledStates[modelID] }),
           cached.lsdDecodeSteps == steps,
           cached.eosThreshold == eosThreshold {
            return cached
        }

        let flowLM = model.flow_lm
        let flowDType = flowLM.input_linear.weight.dtype
        // Decoder-only BF16 checkpoints (such as Gradium Phonon) ship FlowLM in
        // BF16 and Mimi in F32. Converting Mimi's decoder weights to BF16 once
        // matches Pocket TTS's native BF16 Mimi precision, halving 24 kHz
        // SeanetDecoder memory bandwidth and GPU footprint.
        if flowDType == .bfloat16,
           model.mimi.encoder == nil,
           model.mimi.quantizer.output_proj.weight.dtype == .float32 {
            let mimiBF16 = model.mimi.parameters().mapValues { $0.asType(.bfloat16) }
            model.mimi.update(parameters: mimiBF16)
            eval(model.mimi.parameters())
        }
        let mimiDType = model.mimi.quantizer.output_proj.weight.dtype

        var conditioningEmbedding = flowLM.num_speakers?(MLXArray([Int32(1)]))
        if let duration = flowLM.duration_delta?(MLXArray([Float(0)])) {
            conditioningEmbedding = conditioningEmbedding.map { $0 + duration } ?? duration
        }
        if let emb = conditioningEmbedding {
            let typed = emb.asType(flowDType)
            eval(typed)
            conditioningEmbedding = typed
        }

        let flowNet = flowLM.flow_net
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
            tCombined = (tCombined / MLXArray(numTimeConds)).asType(flowDType)
            eval(tCombined)
            precomputedTimeConds.append(tCombined)
        }

        let useExactGELU = model.config.flowLM.transformer.gelu == "erf"
        let numLayers = flowLM.transformer.layers.count
        let offsetArrays = (0..<preallocatedOffsetCount).map { MLXArray(Int32($0)) }
        eval(offsetArrays)
        let depthwiseUpsample = extractDepthwiseUpsampleWeights(from: model.mimi, dtype: mimiDType)

        let state = CompiledModelState(
            flowDType: flowDType,
            mimiDType: mimiDType,
            conditioningEmbedding: conditioningEmbedding,
            useExactGELU: useExactGELU,
            lsdDecodeSteps: steps,
            eosThreshold: eosThreshold,
            numLayers: numLayers,
            offsetArrays: offsetArrays,
            timeConds: precomputedTimeConds,
            depthwiseUpsample: depthwiseUpsample,
            compiledStepsByCapacity: [:],
            compiledQuadStepsByCapacity: [:]
        )
        cacheLock.withLock {
            cacheStore.compiledStates[modelID] = state
        }
        return state
    }

    static func cacheCapacity(forTotalLength total: Int) -> Int {
        if total <= 320 { return 320 }
        if total <= 512 { return 512 }
        if total <= 1024 { return 1024 }
        return ((total + 255) / 256) * 256
    }

    private static func padKVCaches(
        keys: inout [MLXArray],
        values: inout [MLXArray],
        toCapacity capacity: Int,
        dtype: DType
    ) {
        for i in 0..<keys.count {
            let currentLen = keys[i].shape[2]
            if currentLen < capacity {
                let padShape = [keys[i].shape[0], keys[i].shape[1], capacity - currentLen, keys[i].shape[3]]
                let zeros = MLXArray.zeros(padShape, dtype: dtype)
                keys[i] = concatenated([keys[i], zeros], axis: 2)
                values[i] = concatenated([values[i], zeros], axis: 2)
            }
        }
    }

    @inline(__always)
    private static func traceSingleFlowStep(
        sequence: MLXArray,
        noise: MLXArray,
        offsetArray: MLXArray,
        keys: inout [MLXArray],
        values: inout [MLXArray],
        flowLM: FlowLMModel,
        flowDType: DType,
        useExactGELU: Bool,
        eosThreshold: Float,
        invSteps: MLXArray,
        timeConds: [MLXArray],
        condEmb: MLXArray?,
        posWrite: MLXArray,
        posMask: MLXArray,
        zeroMaskVal: MLXArray,
        negInfMaskVal: MLXArray
    ) -> (latent: MLXArray, isEos: MLXArray) {
        let writeMask = posWrite .== offsetArray
        let attnMask = MLX.where(posMask .<= offsetArray, zeroMaskVal, negInfMaskVal)

        var h = flowLM.input_linear(sequence)
        if let condEmb {
            h = h + condEmb
        }

        for (layerIdx, layer) in flowLM.transformer.layers.enumerated() {
            let attn = layer.self_attn
            let norm1Out = layer.norm1(h).asType(flowDType)
            let projected = attn.in_proj(norm1Out)
                .reshaped([1, 1, 3, attn.numHeads, attn.headDim])
            var q = swappedAxes(projected[0..., 0..., 0, 0..., 0...], 1, 2)
            var k = swappedAxes(projected[0..., 0..., 1, 0..., 0...], 1, 2)
            let v = swappedAxes(projected[0..., 0..., 2, 0..., 0...], 1, 2)

            let base = Float(attn.rope.maxPeriod)
            q = MLXFast.RoPE(
                q,
                dimensions: attn.headDim,
                traditional: true,
                base: base,
                scale: 1.0,
                offset: offsetArray
            )
            k = MLXFast.RoPE(
                k,
                dimensions: attn.headDim,
                traditional: true,
                base: base,
                scale: 1.0,
                offset: offsetArray
            )

            let nextK = MLX.where(writeMask, k, keys[layerIdx])
            let nextV = MLX.where(writeMask, v, values[layerIdx])
            keys[layerIdx] = nextK
            values[layerIdx] = nextV

            let attnOut = MLXFast.scaledDotProductAttention(
                queries: q,
                keys: nextK,
                values: nextV,
                scale: attn.scale,
                mask: .array(attnMask)
            )
            let merged = swappedAxes(attnOut, 1, 2).reshaped([1, 1, attn.embedDim])
            let projectedOut = attn.out_proj(merged)
            if let scale1 = layer.layer_scale_1 {
                h = h + scale1(projectedOut).asType(flowDType)
            } else {
                h = h + projectedOut
            }

            let norm2Out = layer.norm2(h).asType(flowDType)
            let hidden = layer.linear1(norm2Out)
            let ff = layer.linear2(useExactGELU ? gelu(hidden) : geluApproximate(hidden))
            if let scale2 = layer.layer_scale_2 {
                h = h + scale2(ff).asType(flowDType)
            } else {
                h = h + ff
            }
        }

        let lastToken = flowLM.out_norm(h).squeezed(axis: 1).asType(flowDType)
        let eosLogits = flowLM.out_eos(lastToken)
        let isEos = eosLogits[0, 0] .> eosThreshold

        let flowNet = flowLM.flow_net
        let cc = flowNet.cond_embed(lastToken)
        var current = noise
        for tCombined in timeConds {
            let y = tCombined + cc
            var xx = flowNet.input_proj(current)
            for block in flowNet.res_blocks {
                xx = block(xx, y).asType(flowDType)
            }
            let flowDir = flowNet.final_layer(xx, y).asType(flowDType)
            current = current + flowDir * invSteps
        }

        return (current.expandedDimensions(axis: 1), isEos)
    }

    private static func compiledFlowStep(
        for model: PocketTTSModel,
        state: CompiledModelState,
        capacity: Int
    ) -> @Sendable ([MLXArray]) -> [MLXArray] {
        let modelID = ObjectIdentifier(model)
        if let cached = cacheLock.withLock({
            cacheStore.compiledStates[modelID]?.compiledStepsByCapacity[capacity]
        }) {
            return cached
        }

        let flowLM = model.flow_lm
        let flowDType = state.flowDType
        let useExactGELU = state.useExactGELU
        let eosThreshold = state.eosThreshold
        let numLayers = state.numLayers
        let invSteps = MLXArray(Float(1.0) / Float(state.lsdDecodeSteps)).asType(flowDType)
        let timeConds = state.timeConds
        let condEmb = state.conditioningEmbedding
        let posWrite = MLXArray(0..<Int32(capacity)).reshaped([1, 1, capacity, 1])
        let posMask = MLXArray(0..<Int32(capacity)).reshaped([1, 1, 1, capacity])
        let zeroMaskVal = MLXArray(Float(0)).asType(flowDType)
        let negInfMaskVal = MLXArray(Float(-1e9)).asType(flowDType)
        eval(posWrite, posMask, zeroMaskVal, negInfMaskVal)

        let fn = compile(
            inputs: [flowLM],
            outputs: [],
            shapeless: false
        ) { (args: [MLXArray]) -> [MLXArray] in
            var keys: [MLXArray] = []
            var values: [MLXArray] = []
            keys.reserveCapacity(numLayers)
            values.reserveCapacity(numLayers)
            for i in 0..<numLayers {
                keys.append(args[3 + i * 2])
                values.append(args[4 + i * 2])
            }

            let (nextLatent, isEos) = traceSingleFlowStep(
                sequence: args[0],
                noise: args[1],
                offsetArray: args[2],
                keys: &keys,
                values: &values,
                flowLM: flowLM,
                flowDType: flowDType,
                useExactGELU: useExactGELU,
                eosThreshold: eosThreshold,
                invSteps: invSteps,
                timeConds: timeConds,
                condEmb: condEmb,
                posWrite: posWrite,
                posMask: posMask,
                zeroMaskVal: zeroMaskVal,
                negInfMaskVal: negInfMaskVal
            )

            var outputs: [MLXArray] = []
            outputs.reserveCapacity(2 + numLayers * 2)
            outputs.append(nextLatent)
            outputs.append(isEos)
            for i in 0..<numLayers {
                outputs.append(keys[i])
                outputs.append(values[i])
            }
            return outputs
        }

        cacheLock.withLock {
            cacheStore.compiledStates[modelID]?.compiledStepsByCapacity[capacity] = fn
        }
        return fn
    }

    private static func compiledFlowStep4(
        for model: PocketTTSModel,
        state: CompiledModelState,
        capacity: Int
    ) -> @Sendable ([MLXArray]) -> [MLXArray] {
        let modelID = ObjectIdentifier(model)
        if let cached = cacheLock.withLock({
            cacheStore.compiledStates[modelID]?.compiledQuadStepsByCapacity[capacity]
        }) {
            return cached
        }

        let flowLM = model.flow_lm
        let flowDType = state.flowDType
        let useExactGELU = state.useExactGELU
        let eosThreshold = state.eosThreshold
        let numLayers = state.numLayers
        let invSteps = MLXArray(Float(1.0) / Float(state.lsdDecodeSteps)).asType(flowDType)
        let timeConds = state.timeConds
        let condEmb = state.conditioningEmbedding
        let posWrite = MLXArray(0..<Int32(capacity)).reshaped([1, 1, capacity, 1])
        let posMask = MLXArray(0..<Int32(capacity)).reshaped([1, 1, 1, capacity])
        let zeroMaskVal = MLXArray(Float(0)).asType(flowDType)
        let negInfMaskVal = MLXArray(Float(-1e9)).asType(flowDType)
        eval(posWrite, posMask, zeroMaskVal, negInfMaskVal)

        let fn = compile(
            inputs: [flowLM],
            outputs: [],
            shapeless: false
        ) { (args: [MLXArray]) -> [MLXArray] in
            var sequence = args[0]
            let noise4 = args[1]
            var keys: [MLXArray] = []
            var values: [MLXArray] = []
            keys.reserveCapacity(numLayers)
            values.reserveCapacity(numLayers)
            for i in 0..<numLayers {
                keys.append(args[2 + quadStepSize + i * 2])
                values.append(args[3 + quadStepSize + i * 2])
            }

            var latents: [MLXArray] = []
            var eosFlags: [MLXArray] = []
            latents.reserveCapacity(quadStepSize)
            eosFlags.reserveCapacity(quadStepSize)

            for sub in 0..<quadStepSize {
                let (nextLatent, isEos) = traceSingleFlowStep(
                    sequence: sequence,
                    noise: noise4[sub],
                    offsetArray: args[2 + sub],
                    keys: &keys,
                    values: &values,
                    flowLM: flowLM,
                    flowDType: flowDType,
                    useExactGELU: useExactGELU,
                    eosThreshold: eosThreshold,
                    invSteps: invSteps,
                    timeConds: timeConds,
                    condEmb: condEmb,
                    posWrite: posWrite,
                    posMask: posMask,
                    zeroMaskVal: zeroMaskVal,
                    negInfMaskVal: negInfMaskVal
                )
                latents.append(nextLatent)
                eosFlags.append(isEos)
                sequence = nextLatent
            }

            var outputs: [MLXArray] = []
            outputs.reserveCapacity(2 + numLayers * 2)
            outputs.append(concatenated(latents, axis: 1))
            outputs.append(stacked(eosFlags, axis: 0))
            for i in 0..<numLayers {
                outputs.append(keys[i])
                outputs.append(values[i])
            }
            return outputs
        }

        cacheLock.withLock {
            cacheStore.compiledStates[modelID]?.compiledQuadStepsByCapacity[capacity] = fn
        }
        return fn
    }

    @inline(__always)
    private static func offsetScalar(_ offset: Int, cached: [MLXArray]) -> MLXArray {
        if offset >= 0 && offset < cached.count {
            return cached[offset]
        }
        return MLXArray(Int32(offset))
    }

    private static func runPrefillTransformer(
        _ transformer: PocketStreamingTransformer,
        input: MLXArray,
        keys: inout [MLXArray],
        values: inout [MLXArray],
        offset: inout Int,
        computeDType: DType,
        useExactGELU: Bool
    ) -> MLXArray {
        let t = input.shape[1]
        let currentOffset = offset
        var h = input.asType(computeDType)

        for (layerIdx, layer) in transformer.layers.enumerated() {
            let attn = layer.self_attn
            let norm1Out = layer.norm1(h).asType(computeDType)
            let projected = attn.in_proj(norm1Out)
                .reshaped([1, t, 3, attn.numHeads, attn.headDim])
            var q = swappedAxes(projected[0..., 0..., 0, 0..., 0...], 1, 2)
            var k = swappedAxes(projected[0..., 0..., 1, 0..., 0...], 1, 2)
            let v = swappedAxes(projected[0..., 0..., 2, 0..., 0...], 1, 2)

            let base = Float(attn.rope.maxPeriod)
            q = MLXFast.RoPE(
                q,
                dimensions: attn.headDim,
                traditional: true,
                base: base,
                scale: 1.0,
                offset: currentOffset
            )
            k = MLXFast.RoPE(
                k,
                dimensions: attn.headDim,
                traditional: true,
                base: base,
                scale: 1.0,
                offset: currentOffset
            )

            let kFull: MLXArray
            let vFull: MLXArray
            if layerIdx < keys.count {
                kFull = concatenated([keys[layerIdx], k], axis: 2)
                vFull = concatenated([values[layerIdx], v], axis: 2)
                keys[layerIdx] = kFull
                values[layerIdx] = vFull
            } else {
                kFull = k
                vFull = v
                keys.append(kFull)
                values.append(vFull)
            }

            let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = t == 1 ? .none : .causal
            let out = MLXFast.scaledDotProductAttention(
                queries: q,
                keys: kFull,
                values: vFull,
                scale: attn.scale,
                mask: maskMode
            )
            let merged = swappedAxes(out, 1, 2).reshaped([1, t, attn.embedDim])
            let projectedOut = attn.out_proj(merged)
            if let scale1 = layer.layer_scale_1 {
                h = h + scale1(projectedOut).asType(computeDType)
            } else {
                h = h + projectedOut
            }

            let norm2Out = layer.norm2(h).asType(computeDType)
            let hidden = layer.linear1(norm2Out)
            let ff = layer.linear2(useExactGELU ? gelu(hidden) : geluApproximate(hidden))
            if let scale2 = layer.layer_scale_2 {
                h = h + scale2(ff).asType(computeDType)
            } else {
                h = h + ff
            }
        }

        offset = currentOffset + t
        return h
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
        let snapshot = try initialVoiceState(
            model: model,
            conditioning: conditioning,
            compiled: compiled
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

    private static func initialVoiceState(
        model: PocketTTSModel,
        conditioning rawConditioning: MLXArray,
        compiled: CompiledModelState
    ) throws -> CachedVoiceState {
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

        var keys: [MLXArray] = []
        var values: [MLXArray] = []
        keys.reserveCapacity(compiled.numLayers)
        values.reserveCapacity(compiled.numLayers)
        var offset = 0

        if conditioning.shape[1] > 0 {
            _ = runPrefillTransformer(
                model.flow_lm.transformer,
                input: conditioning.asType(compiled.flowDType),
                keys: &keys,
                values: &values,
                offset: &offset,
                computeDType: compiled.flowDType,
                useExactGELU: compiled.useExactGELU
            )
        } else {
            let numHeads = model.flow_lm.transformer.numHeads
            let headDim = model.flow_lm.transformer.headDim
            for _ in 0..<compiled.numLayers {
                let empty = MLXArray.zeros([1, numHeads, 0, headDim], dtype: compiled.flowDType)
                keys.append(empty)
                values.append(empty)
            }
        }

        eval(keys + values)
        return CachedVoiceState(
            keys: keys,
            values: values,
            promptNumFrames: offset
        )
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
