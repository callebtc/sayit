import SayItCore

protocol BackendSpeechSynthesizing: SpeechSynthesizing {
    func updateConfiguration(
        chunkTarget: Int,
        chunkDelay: Double,
        paragraphPause: Double,
        idleUnloadDelay: Double
    ) async

    func prepareDependencies(for model: ModelDescriptor) async throws

    func generateVoiceSample(
        model: ModelDescriptor,
        text: String,
        language: String?,
        tuning: VoiceSynthesisTuning,
        seed: UInt64,
        reference: VoiceReference?
    ) async throws -> GeneratedVoiceSample

    func preloadModel(
        _ model: ModelDescriptor,
        voice: String?,
        voiceReference: VoiceReference?,
        language: String?
    ) async
}

extension BackendSpeechSynthesizing {
    func preloadModel(
        _ model: ModelDescriptor,
        voice: String?,
        voiceReference: VoiceReference?,
        language: String?
    ) async {
        _ = (model, voice, voiceReference, language)
    }
}
