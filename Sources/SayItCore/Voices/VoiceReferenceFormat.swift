public enum VoiceReferenceFormat {
    public static func sampleRate(forModelType modelType: String) -> Double {
        switch modelType.lowercased() {
        case "fish_qwen3_omni", "fish_speech":
            44_100
        default:
            24_000
        }
    }
}
