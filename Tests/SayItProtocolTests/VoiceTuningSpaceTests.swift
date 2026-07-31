import Foundation
import SayItProtocol
import Testing

@Suite("Voice tuning space")
struct VoiceTuningSpaceTests {
    private let modelTypes = [
        "qwen3_tts", "fish_speech", "chatterbox", "omnivoice"
    ]

    @Test("Slider anchors land on preset defaults")
    func interpolationAnchors() {
        for modelType in modelTypes {
            let anchors: [(Double, VoiceTuningPreset)] = [
                (0, .faithful),
                (0.5, .natural),
                (1, .expressive)
            ]
            for (position, preset) in anchors {
                let tuning = VoiceTuningSpace.interpolated(
                    modelType: modelType,
                    position: position
                )
                #expect(tuning.preset == preset)
                let expected = VoiceTuningSpace.defaults(
                    modelType: modelType,
                    preset: preset
                )
                #expect(Set(tuning.parameters.keys) == Set(expected.keys))
                for (key, value) in expected {
                    let actual = tuning.parameters[key] ?? .nan
                    #expect(abs(actual - value) < 1e-9)
                }
            }
        }
    }

    @Test("Interpolated and randomized values stay inside the parameter ranges")
    func valuesStayInRange() {
        for modelType in modelTypes {
            let ranges = VoiceTuningSpace.ranges(modelType: modelType)
            for step in stride(from: 0.0, through: 1.0, by: 0.05) {
                let tuning = VoiceTuningSpace.interpolated(
                    modelType: modelType,
                    position: step
                )
                #expect(Set(tuning.parameters.keys) == Set(ranges.keys))
                #expect(tuning.parameters.allSatisfy {
                    ranges[$0.key]?.contains($0.value) == true
                })
            }
            for _ in 0..<50 {
                let tuning = VoiceTuningSpace.randomized(modelType: modelType)
                #expect(Set(tuning.parameters.keys) == Set(ranges.keys))
                #expect(tuning.parameters.allSatisfy {
                    ranges[$0.key]?.contains($0.value) == true
                })
            }
        }
    }

    @Test("Randomized tunings produce variety between candidates")
    func randomizedProducesVariety() {
        let tunings = (0..<4).map { _ in
            VoiceTuningSpace.randomized(modelType: "qwen3_tts")
        }
        #expect(tunings.contains { $0 != tunings[0] })
    }

    @Test("Clamping snaps values to the parameter step")
    func clampingSnapsToStep() {
        let parameter = VoiceTuningParameter(
            key: "temperature",
            title: "Temperature",
            range: 0.2...1.2,
            step: 0.05
        )
        #expect(abs(parameter.clamped(0.432) - 0.45) < 1e-9)
        #expect(abs(parameter.clamped(-3) - 0.2) < 1e-9)
        #expect(abs(parameter.clamped(9) - 1.2) < 1e-9)
    }

    @Test("Nearest preset follows slider thirds")
    func nearestPresetBoundaries() {
        #expect(VoiceTuningSpace.nearestPreset(position: 0) == .faithful)
        #expect(VoiceTuningSpace.nearestPreset(position: 0.24) == .faithful)
        #expect(VoiceTuningSpace.nearestPreset(position: 0.25) == .natural)
        #expect(VoiceTuningSpace.nearestPreset(position: 0.74) == .natural)
        #expect(VoiceTuningSpace.nearestPreset(position: 0.75) == .expressive)
        #expect(VoiceTuningSpace.nearestPreset(position: 1) == .expressive)
    }

    @Test("Per-candidate tunings survive a discovery request round trip")
    func candidateTuningsRoundTrip() throws {
        let request = VoiceDiscoveryRequest(
            modelID: "qwen3-06b-base-8bit",
            language: "en-US",
            sampleText: "A sample worth hearing twice.",
            candidateTunings: [
                VoiceTuningSpace.interpolated(
                    modelType: "qwen3_tts",
                    position: 0.2
                ),
                VoiceTuningSpace.randomized(modelType: "qwen3_tts")
            ]
        )
        let decoded = try JSONDecoder().decode(
            VoiceDiscoveryRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)
        #expect(decoded.candidateTunings?.count == 2)
    }
}
