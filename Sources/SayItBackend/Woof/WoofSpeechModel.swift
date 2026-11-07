import Foundation
@preconcurrency import MLX
import MLXAudioCore

/// Woof's text-to-latent model.
///
/// A causal transformer reads a 16-vector voice prompt and the characters to
/// speak, then emits one 32-dimensional latent per 40 ms frame. Each latent
/// comes from a one-step flow head conditioned on the transformer state, and
/// generation stops when the state's end-of-speech logit crosses a threshold.
final class WoofSpeechModel {
    private struct Layer {
        let attention: WoofLinear
        let output: WoofLinear
        let gateAndUp: WoofLinear
        let down: WoofLinear
    }

    struct Generation {
        let latents: MLXArray
        let reachedEnd: Bool
    }

    /// Prompt and generated frames share this many positions.
    static let maximumPositions = 1_100
    private static let minimumFrames = 3
    private static let alphabet = Array(
        " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?;:'\"-()&/%$€£@#+=*_<>[]…—"
    )
    private static let tokenByCharacter = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, Int32($0 + 3)) }
    )

    private let layers: [Layer]
    private let conditioning: WoofLinear
    private let modulation: WoofLinear
    private let headBlocks: [(inner: WoofLinear, outer: WoofLinear)]
    private let latentInput: WoofLinear
    private let headInput: WoofLinear
    private let headOutput: WoofLinear
    private let textEmbedding: MLXArray
    private let beginning: MLXArray
    private let normalizationWeight: MLXArray
    private let heads: Int
    private let headDimension: Int
    private let feedForwardWidth: Int
    private let headWidth: Int
    private let ropeBase: Float
    let latentWidth: Int

    init(tree: WoofWeightTree) throws {
        let config = try tree.child("cfg")
        let width = try config.child("d").int()
        heads = try config.child("H").int()
        headDimension = width / heads
        feedForwardWidth = try config.child("ff").int()
        headWidth = try config.child("hw").int()
        latentWidth = try config.child("latent").int()
        ropeBase = try config.child("rope_base").float()
        let depth = try config.child("depth").int()
        guard width == heads * headDimension, depth > 0 else {
            throw WoofModelError.invalidWeights("speech configuration is inconsistent")
        }

        layers = try tree.child("layers").elements().map { layer in
            let projections = try layer.elements().map { try $0.linear() }
            guard projections.count == 4 else {
                throw WoofModelError.invalidWeights("speech layers need four projections")
            }
            return Layer(
                attention: projections[0],
                output: projections[1],
                gateAndUp: projections[2],
                down: projections[3]
            )
        }
        guard layers.count == (try config.child("L").int()) else {
            throw WoofModelError.invalidWeights("speech layer count is inconsistent")
        }
        conditioning = try tree.child("ce").linear()
        modulation = try tree.child("ada").linear()
        headBlocks = try tree.child("hblocks").elements().map { block in
            (try block.element(0).linear(), try block.element(1).linear())
        }
        guard headBlocks.count == depth else {
            throw WoofModelError.invalidWeights("flow head depth is inconsistent")
        }
        latentInput = try tree.child("lat_in").linear()
        headInput = try tree.child("h_inp").linear()
        headOutput = try tree.child("h_out").linear()
        textEmbedding = try tree.child("text_emb").tensor()
        beginning = try tree.child("bos").tensor().reshaped(1, width)
        normalizationWeight = MLXArray.ones([width])
    }

    /// Token 1 starts the text; characters outside Woof's alphabet become 2.
    static func tokens(for text: String) -> [Int32] {
        [1] + text.map { tokenByCharacter[$0] ?? 2 }
    }

    /// Generates latents for one utterance.
    ///
    /// - Parameter noise: Returns a `(1, latentWidth)` standard normal draw.
    func generate(
        voice: MLXArray,
        tokens: [Int32],
        maximumFrames: Int,
        temperature: Float,
        stopProbability: Float = 0.9,
        noise: () -> MLXArray
    ) throws -> Generation {
        let prompt = concatenated(
            [voice, textEmbedding[MLXArray(tokens)], beginning],
            axis: 0
        )
        let promptLength = prompt.dim(0)
        let frameLimit = min(maximumFrames, Self.maximumPositions - promptLength)
        guard frameLimit > Self.minimumFrames else {
            throw WoofModelError.inputTooLong
        }

        let caches = layers.map { _ in KVCacheSimple() }
        var hidden = prompt
        for index in layers.indices {
            hidden = block(index, hidden, offset: 0, cache: caches[index], mask: .causal)
        }
        var (state, stopLogit) = condition(hidden[(promptLength - 1)...])
        let stopThreshold = log(stopProbability / (1 - stopProbability))

        var frames: [MLXArray] = []
        frames.reserveCapacity(frameLimit)
        for frame in 0..<frameLimit {
            try Task.checkCancellation()
            if frame > Self.minimumFrames, stopLogit.item(Float.self) > stopThreshold {
                return Generation(latents: concatenated(frames, axis: 0), reachedEnd: true)
            }
            let draw = noise() * temperature
            let latent = draw + flowHead(state: state, noise: draw)
            frames.append(latent)
            hidden = latentInput(latent)
            for index in layers.indices {
                hidden = block(
                    index,
                    hidden,
                    offset: promptLength + frame,
                    cache: caches[index],
                    mask: .none
                )
            }
            (state, stopLogit) = condition(hidden)
        }
        return Generation(latents: concatenated(frames, axis: 0), reachedEnd: false)
    }

    private func block(
        _ index: Int,
        _ hidden: MLXArray,
        offset: Int,
        cache: KVCacheSimple,
        mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        let layer = layers[index]
        let length = hidden.dim(0)
        let projected = layer.attention(rmsNormalized(hidden))
            .reshaped(1, length, 3, heads, headDimension)
            .transposed(2, 0, 3, 1, 4)
        let queries = rotated(projected[0], offset: offset)
        let (keys, values) = cache.update(
            keys: rotated(projected[1], offset: offset),
            values: projected[2]
        )
        let attended = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: 1 / Float(headDimension).squareRoot(),
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(length, heads * headDimension)
        let residual = hidden + layer.output(attended)
        let gateAndUp = layer.gateAndUp(rmsNormalized(residual))
        let gate = gateAndUp[0..., ..<feedForwardWidth]
        let up = gateAndUp[0..., feedForwardWidth...]
        return residual + layer.down(silu(gate) * up)
    }

    private func condition(_ hidden: MLXArray) -> (state: MLXArray, stopLogit: MLXArray) {
        let output = conditioning(rmsNormalized(hidden))
        return (silu(output[0..., ..<headWidth]), output[0, headWidth])
    }

    private func flowHead(state: MLXArray, noise: MLXArray) -> MLXArray {
        let modulation = modulation(state)
        func slice(_ index: Int) -> MLXArray {
            modulation[0..., (index * headWidth)..<((index + 1) * headWidth)]
        }
        var hidden = headInput(noise)
        for (index, block) in headBlocks.enumerated() {
            let shifted = slice(3 * index) + layerNormalized(hidden) * slice(3 * index + 1)
            hidden = hidden + slice(3 * index + 2) * block.outer(silu(block.inner(shifted)))
        }
        let final = 3 * headBlocks.count
        return headOutput(slice(final) + layerNormalized(hidden) * slice(final + 1))
    }

    private func rotated(_ x: MLXArray, offset: Int) -> MLXArray {
        MLXFast.RoPE(
            x,
            dimensions: headDimension,
            traditional: false,
            base: ropeBase,
            scale: 1,
            offset: offset
        )
    }

    private func rmsNormalized(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: normalizationWeight, eps: Float.ulpOfOne)
    }

    private func layerNormalized(_ x: MLXArray) -> MLXArray {
        MLXFast.layerNorm(x, eps: 1e-5)
    }

    private func silu(_ x: MLXArray) -> MLXArray {
        x * sigmoid(x)
    }
}
