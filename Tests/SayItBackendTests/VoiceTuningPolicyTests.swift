import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Voice tuning policy")
struct VoiceTuningPolicyTests {
    @Test("All clone model presets provide bounded raw values")
    func presetDefaults() throws {
        let policy = VoiceTuningPolicy()
        for modelType in [
            "qwen3_tts", "fish_speech", "chatterbox", "omnivoice"
        ] {
            for preset in VoiceTuningPreset.allCases {
                let tuning = try policy.validate(
                    VoiceTuning(preset: preset),
                    modelType: modelType
                )
                #expect(!tuning.parameters.isEmpty)
                let ranges = policy.ranges(modelType: modelType)
                #expect(tuning.parameters.allSatisfy {
                    ranges[$0.key]?.contains($0.value) == true
                })
            }
        }
    }

    @Test("Unknown, non-finite, and out-of-range values are rejected")
    func rejectsInvalidValues() {
        let policy = VoiceTuningPolicy()
        for parameters in [
            ["unknown": 1],
            ["temperature": .infinity],
            ["temperature": 9]
        ] {
            #expect(throws: ServiceFailure.self) {
                _ = try policy.validate(
                    VoiceTuning(parameters: parameters),
                    modelType: "qwen3_tts"
                )
            }
        }
    }

    @Test("Interpolated and randomized space tunings pass validation")
    func generatedTuningsValidate() throws {
        let policy = VoiceTuningPolicy()
        for modelType in [
            "qwen3_tts", "fish_speech", "chatterbox", "omnivoice"
        ] {
            for position in stride(from: 0.0, through: 1.0, by: 0.1) {
                let tuning = try policy.validate(
                    VoiceTuningSpace.interpolated(
                        modelType: modelType,
                        position: position
                    ),
                    modelType: modelType
                )
                #expect(!tuning.parameters.isEmpty)
            }
            let randomized = try policy.validate(
                VoiceTuningSpace.randomized(modelType: modelType),
                modelType: modelType
            )
            #expect(!randomized.parameters.isEmpty)
        }
    }
}
