import Foundation


enum SupportedModelTypes {
    private static let aliases: [Set<String>] = [
        ["breeze_tts", "breeze"],
        ["moss_tts_nano"],
        ["moss_tts", "moss_tts_delay", "moss_tts_local"],
        ["echo_tts", "echo"],
        ["irodori_tts", "irodori"],
        ["qwen3_tts"],
        ["qwen3", "qwen"],
        ["fish_speech", "fish_qwen3_omni"],
        [
            "llama_tts", "llama3_tts", "llama3", "llama", "orpheus",
            "orpheus_tts"
        ],
        ["csm", "sesame"],
        ["soprano_tts", "soprano"],
        ["pocket_tts"],
        ["chatterbox", "chatterbox_tts", "chatterbox_turbo"],
        ["kitten_tts", "kitten"],
        ["kokoro", "kokoro_tts"],
        ["omnivoice"],
        ["indextts", "index_tts"]
    ]

    static let all = Set(aliases.flatMap { $0 })

    static func areCompatible(_ catalogType: String, _ declaredType: String) -> Bool {
        let catalogType = catalogType.lowercased()
        let declaredType = declaredType.lowercased()
        return aliases.contains {
            $0.contains(catalogType) && $0.contains(declaredType)
        }
    }
}
