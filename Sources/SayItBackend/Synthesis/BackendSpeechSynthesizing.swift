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
}
