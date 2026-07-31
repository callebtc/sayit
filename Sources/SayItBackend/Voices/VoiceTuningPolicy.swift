import SayItProtocol

struct VoiceTuningPolicy: Sendable {
    func validate(
        _ tuning: VoiceTuning,
        modelType: String
    ) throws -> VoiceTuning {
        let values = defaults(modelType: modelType, preset: tuning.preset)
        let allowed = ranges(modelType: modelType)
        var merged = values
        for (key, value) in tuning.parameters {
            guard value.isFinite,
                  let range = allowed[key],
                  range.contains(value) else {
                throw ServiceFailure(
                    code: "voice.invalid_tuning",
                    message: "One or more voice refinement settings are invalid."
                )
            }
            merged[key] = value
        }
        return VoiceTuning(preset: tuning.preset, parameters: merged)
    }

    func ranges(modelType: String) -> [String: ClosedRange<Double>] {
        VoiceTuningSpace.ranges(modelType: modelType)
    }

    func defaults(
        modelType: String,
        preset: VoiceTuningPreset
    ) -> [String: Double] {
        VoiceTuningSpace.defaults(modelType: modelType, preset: preset)
    }
}
