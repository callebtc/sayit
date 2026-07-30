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
        switch modelType.lowercased() {
        case "qwen3_tts":
            [
                "temperature": 0.2...1.2,
                "topP": 0.5...1,
                "topK": 0...100,
                "repetitionPenalty": 0.9...1.5
            ]
        case "fish_speech":
            [
                "temperature": 0.2...1.2,
                "topP": 0.5...1,
                "topK": 0...100
            ]
        case "chatterbox":
            [
                "temperature": 0.2...1.2,
                "cfg": 0...1,
                "exaggeration": 0...1
            ]
        case "omnivoice":
            [
                "diffusionSteps": 8...64,
                "guidance": 1...5,
                "positionTemperature": 0...10,
                "classTemperature": 0...2,
                "timeShift": 0...1
            ]
        default:
            [:]
        }
    }

    func defaults(
        modelType: String,
        preset: VoiceTuningPreset
    ) -> [String: Double] {
        switch (modelType.lowercased(), preset) {
        case ("qwen3_tts", .faithful):
            [
                "temperature": 0.45,
                "topP": 0.75,
                "topK": 20,
                "repetitionPenalty": 1.3
            ]
        case ("qwen3_tts", .natural):
            [
                "temperature": 0.65,
                "topP": 0.9,
                "topK": 40,
                "repetitionPenalty": 1.2
            ]
        case ("qwen3_tts", .expressive):
            [
                "temperature": 0.85,
                "topP": 0.95,
                "topK": 50,
                "repetitionPenalty": 1.2
            ]
        case ("fish_speech", .faithful):
            ["temperature": 0.55, "topP": 0.65, "topK": 20]
        case ("fish_speech", .natural):
            ["temperature": 0.7, "topP": 0.8, "topK": 35]
        case ("fish_speech", .expressive):
            ["temperature": 0.9, "topP": 0.9, "topK": 50]
        case ("chatterbox", .faithful):
            ["temperature": 0.55, "cfg": 0.65, "exaggeration": 0.25]
        case ("chatterbox", .natural):
            ["temperature": 0.8, "cfg": 0.5, "exaggeration": 0.5]
        case ("chatterbox", .expressive):
            ["temperature": 1, "cfg": 0.35, "exaggeration": 0.8]
        case ("omnivoice", .faithful):
            [
                "diffusionSteps": 48,
                "guidance": 2.8,
                "positionTemperature": 3.5,
                "classTemperature": 0,
                "timeShift": 0.08
            ]
        case ("omnivoice", .natural):
            [
                "diffusionSteps": 32,
                "guidance": 2,
                "positionTemperature": 5,
                "classTemperature": 0,
                "timeShift": 0.1
            ]
        case ("omnivoice", .expressive):
            [
                "diffusionSteps": 28,
                "guidance": 1.6,
                "positionTemperature": 7,
                "classTemperature": 0.35,
                "timeShift": 0.18
            ]
        default:
            [:]
        }
    }
}
