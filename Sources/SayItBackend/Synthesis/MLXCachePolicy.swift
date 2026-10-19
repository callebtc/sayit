import Foundation

/// MLX keeps freed buffers in a reuse cache whose default limit is the device
/// memory limit. Qwen3-TTS encodes the whole voice reference in one graph, so
/// without a cap the gigabytes of freed encoder activations stay resident for
/// the rest of the session (about 0.13 GB per reference second).
enum MLXCachePolicy {
    /// Measured on qwen3-06b-base-8bit: a 1 GiB cap keeps peak footprint at
    /// 4.4–5.0 GB for 10–42 s references without changing latency, whereas
    /// 0 and 256 MiB caps raised the real-time factor by up to 4x.
    static let qwen3TTSCacheLimit = 1 << 30

    static func cacheLimit(
        forModelType modelType: String,
        defaultLimit: Int
    ) -> Int {
        switch modelType.lowercased() {
        case "qwen3_tts":
            min(qwen3TTSCacheLimit, defaultLimit)
        default:
            defaultLimit
        }
    }
}
