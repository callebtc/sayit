import Foundation
@preconcurrency import MLX
import MLXAudioCore

/// Woof's audio decoder, which Underdog adapted from Kyutai's Mimi.
///
/// A windowed causal transformer refines the latent frames, then a causal
/// SEANet stack upsamples them 960 times to 24 kHz mono samples. The whole
/// utterance is decoded at once; causal padding matches streaming state.
final class WoofDecoder {
    private struct TransformerLayer {
        let firstNorm: (weight: MLXArray, bias: MLXArray)
        let secondNorm: (weight: MLXArray, bias: MLXArray)
        let attention: MLXArray
        let output: MLXArray
        let up: MLXArray
        let down: MLXArray

        init(tree: WoofWeightTree) throws {
            func norm(_ key: String) throws -> (MLXArray, MLXArray) {
                let values = try tree.child(key).elements()
                guard values.count == 2 else {
                    throw WoofModelError.invalidWeights("decoder \(key) needs a weight and bias")
                }
                return (try values[0].dequantized(), try values[1].dequantized())
            }
            firstNorm = try norm("ln1")
            secondNorm = try norm("ln2")
            attention = try tree.child("qkv").dequantized().transposed()
            output = try tree.child("o").dequantized().transposed()
            up = try tree.child("fc1").dequantized().transposed()
            down = try tree.child("fc2").dequantized().transposed()
        }
    }

    /// A causal convolution, stored as `(output, kernel, input)` for MLX.
    private struct Convolution {
        let weight: MLXArray
        let bias: MLXArray

        init(tree: WoofWeightTree) throws {
            weight = try tree.child("w").dequantized().transposed(0, 2, 1)
            bias = try tree.child("b").dequantized()
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let kernel = weight.dim(1)
            let input = kernel > 1
                ? padded(x, widths: [[0, 0], [kernel - 1, 0], [0, 0]])
                : x
            return conv1d(input, weight) + bias
        }
    }

    /// A causal transposed convolution whose kernel spans two strides: each
    /// frame writes `stride` samples and adds its tail to the next frame's.
    private struct Upsample {
        let weight: MLXArray
        let bias: MLXArray
        let stride: Int
        let channels: Int

        init(tree: WoofWeightTree) throws {
            let stored = try tree.child("w").dequantized()
            stride = try tree.child("stride").int()
            channels = stored.dim(1)
            guard stored.dim(2) == 2 * stride else {
                throw WoofModelError.invalidWeights("decoder upsampling kernel must span two strides")
            }
            weight = stored.transposed(0, 2, 1).reshaped(stored.dim(0), -1)
            bias = tiled(try tree.child("b").dequantized(), repetitions: [stride])
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let frames = x.dim(1)
            let width = stride * channels
            let projected = matmul(x, weight)
            let carried = padded(
                projected[0..., 0..., width...],
                widths: [[0, 0], [1, 0], [0, 0]]
            )[0..., ..<frames]
            return (projected[0..., 0..., ..<width] + carried + bias)
                .reshaped(1, frames * stride, channels)
        }
    }

    private enum Stage {
        case convolution(Convolution)
        case elu
        case upsample(Upsample)
        case residual(Convolution, Convolution)
    }

    private let inputProjection: MLXArray
    private let inputBias: MLXArray
    /// Rotary wavelengths: the reciprocal of the stored inverse frequencies.
    private let periods: MLXArray
    private let layers: [TransformerLayer]
    private let stages: [Stage]
    private let heads: Int
    private let headDimension: Int
    private let window: Int
    private let epsilon: Float

    init(tree: WoofWeightTree) throws {
        let config = try tree.child("cfg")
        heads = try config.child("heads").int()
        headDimension = try config.child("head_dim").int()
        window = try config.child("window").int()
        epsilon = try config.child("eps").float()
        let input = try tree.child("inp")
        inputProjection = try input.element(0).dequantized().transposed()
        inputBias = try input.element(1).dequantized()
        periods = 1 / (try tree.child("inv_freq").tensor())
        guard periods.dim(0) * 2 == headDimension else {
            throw WoofModelError.invalidWeights("decoder rotary frequencies are inconsistent")
        }
        layers = try tree.child("tf").elements().map(TransformerLayer.init)
        stages = try tree.child("seanet").elements().map { stage in
            switch try stage.element(0).string() {
            case "conv":
                .convolution(try Convolution(tree: stage.element(1)))
            case "elu":
                .elu
            case "convt":
                .upsample(try Upsample(tree: stage.element(1)))
            case "res":
                .residual(
                    try Convolution(tree: stage.element(1).element(0)),
                    try Convolution(tree: stage.element(1).element(1))
                )
            case let kind:
                throw WoofModelError.invalidWeights("unknown decoder stage \(kind)")
            }
        }
    }

    /// Decodes `(frames, 32)` latents to mono samples.
    func callAsFunction(_ latents: MLXArray) -> MLXArray {
        var audio = transformer(matmul(latents, inputProjection) + inputBias)
            .expandedDimensions(axis: 0)
        for stage in stages {
            switch stage {
            case .convolution(let convolution):
                audio = convolution(audio)
            case .elu:
                audio = elu(audio)
            case .upsample(let upsample):
                audio = upsample(audio)
            case .residual(let first, let second):
                audio = audio + second(elu(first(elu(audio))))
            }
        }
        return audio.reshaped(-1)
    }

    private func transformer(_ input: MLXArray) -> MLXArray {
        let frames = input.dim(0)
        let visible = createCausalMask(n: frames, offset: 0, windowSize: window)

        func rotated(_ x: MLXArray) -> MLXArray {
            MLXFast.RoPE(
                x, dimensions: headDimension, traditional: false,
                base: nil, scale: 1, offset: 0, freqs: periods
            )
        }

        var hidden = input
        for layer in layers {
            let normalized = MLXFast.layerNorm(
                hidden,
                weight: layer.firstNorm.weight,
                bias: layer.firstNorm.bias,
                eps: epsilon
            )
            let projected = matmul(normalized, layer.attention)
                .reshaped(frames, 3, heads, headDimension)
                .transposed(1, 2, 0, 3)
            let attended = MLXFast.scaledDotProductAttention(
                queries: rotated(projected[0]).expandedDimensions(axis: 0),
                keys: rotated(projected[1]).expandedDimensions(axis: 0),
                values: projected[2].expandedDimensions(axis: 0),
                scale: 1 / Float(headDimension).squareRoot(),
                mask: .array(visible)
            )
            .transposed(0, 2, 1, 3)
            .reshaped(frames, heads * headDimension)
            hidden = hidden + matmul(attended, layer.output)
            let refined = MLXFast.layerNorm(
                hidden,
                weight: layer.secondNorm.weight,
                bias: layer.secondNorm.bias,
                eps: epsilon
            )
            hidden = hidden + matmul(gelu(matmul(refined, layer.up)), layer.down)
        }
        return hidden
    }

    private func elu(_ x: MLXArray) -> MLXArray {
        which(x .> 0, x, expm1(x))
    }

    private func gelu(_ x: MLXArray) -> MLXArray {
        0.5 * x * (1 + erf(x / Float(2).squareRoot()))
    }
}
