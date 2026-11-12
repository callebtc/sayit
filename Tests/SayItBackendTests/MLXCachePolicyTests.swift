import Testing
@testable import SayItBackend

@Suite("MLX cache policy")
struct MLXCachePolicyTests {
    @Test("Qwen3-TTS caps the MLX buffer cache at 1 GiB")
    func qwenIsCapped() {
        let defaultLimit = 96 << 30
        #expect(
            MLXCachePolicy.cacheLimit(
                forModelType: "qwen3_tts",
                defaultLimit: defaultLimit
            ) == 1 << 30
        )
        #expect(
            MLXCachePolicy.cacheLimit(
                forModelType: "QWEN3_TTS",
                defaultLimit: defaultLimit
            ) == 1 << 30
        )
    }

    @Test("A smaller default limit is never raised")
    func smallerDefaultWins() {
        #expect(
            MLXCachePolicy.cacheLimit(
                forModelType: "qwen3_tts",
                defaultLimit: 512 << 20
            ) == 512 << 20
        )
    }

    @Test("Other models keep the default limit", arguments: [
        "kokoro", "chatterbox", "fish_qwen3_omni", "qwen3", "omnivoice"
    ])
    func otherModelsUseDefault(modelType: String) {
        #expect(
            MLXCachePolicy.cacheLimit(
                forModelType: modelType,
                defaultLimit: 96 << 30
            ) == 96 << 30
        )
    }
}
