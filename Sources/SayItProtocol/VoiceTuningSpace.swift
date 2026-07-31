import Foundation

public struct VoiceTuningParameter: Codable, Equatable, Sendable {
    public let key: String
    public let title: String
    public let range: ClosedRange<Double>
    public let step: Double

    public init(
        key: String,
        title: String,
        range: ClosedRange<Double>,
        step: Double
    ) {
        self.key = key
        self.title = title
        self.range = range
        self.step = step
    }

    public func clamped(_ value: Double) -> Double {
        let stepped = (value / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

public enum VoiceTuningSpace {
    public static func parameters(modelType: String) -> [VoiceTuningParameter] {
        switch modelType.lowercased() {
        case "qwen3_tts":
            [
                VoiceTuningParameter(
                    key: "temperature",
                    title: "Temperature",
                    range: 0.2...1.2,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "topP",
                    title: "Top P",
                    range: 0.5...1,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "topK",
                    title: "Top K",
                    range: 0...100,
                    step: 1
                ),
                VoiceTuningParameter(
                    key: "repetitionPenalty",
                    title: "Repetition",
                    range: 0.9...1.5,
                    step: 0.05
                )
            ]
        case "fish_speech":
            [
                VoiceTuningParameter(
                    key: "temperature",
                    title: "Temperature",
                    range: 0.2...1.2,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "topP",
                    title: "Top P",
                    range: 0.5...1,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "topK",
                    title: "Top K",
                    range: 0...100,
                    step: 1
                )
            ]
        case "chatterbox":
            [
                VoiceTuningParameter(
                    key: "temperature",
                    title: "Temperature",
                    range: 0.2...1.2,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "cfg",
                    title: "CFG",
                    range: 0...1,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "exaggeration",
                    title: "Exaggeration",
                    range: 0...1,
                    step: 0.05
                )
            ]
        case "omnivoice":
            [
                VoiceTuningParameter(
                    key: "diffusionSteps",
                    title: "Diffusion Steps",
                    range: 8...64,
                    step: 1
                ),
                VoiceTuningParameter(
                    key: "guidance",
                    title: "Guidance",
                    range: 1...5,
                    step: 0.1
                ),
                VoiceTuningParameter(
                    key: "positionTemperature",
                    title: "Position Temperature",
                    range: 0...10,
                    step: 0.25
                ),
                VoiceTuningParameter(
                    key: "classTemperature",
                    title: "Class Temperature",
                    range: 0...2,
                    step: 0.05
                ),
                VoiceTuningParameter(
                    key: "timeShift",
                    title: "Time Shift",
                    range: 0...1,
                    step: 0.02
                )
            ]
        default:
            []
        }
    }

    public static func ranges(
        modelType: String
    ) -> [String: ClosedRange<Double>] {
        Dictionary(
            uniqueKeysWithValues: parameters(modelType: modelType).map {
                ($0.key, $0.range)
            }
        )
    }

    public static func defaults(
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

    public static func interpolated(
        modelType: String,
        position: Double
    ) -> VoiceTuning {
        let clamped = min(max(position, 0), 1)
        let from = defaults(
            modelType: modelType,
            preset: clamped <= 0.5 ? .faithful : .natural
        )
        let to = defaults(
            modelType: modelType,
            preset: clamped <= 0.5 ? .natural : .expressive
        )
        let fraction = clamped <= 0.5
            ? clamped * 2
            : (clamped - 0.5) * 2
        var values: [String: Double] = [:]
        for parameter in parameters(modelType: modelType) {
            let lower = from[parameter.key] ?? parameter.range.lowerBound
            let upper = to[parameter.key] ?? parameter.range.upperBound
            values[parameter.key] = parameter.clamped(
                lower + (upper - lower) * fraction
            )
        }
        return VoiceTuning(
            preset: nearestPreset(position: clamped),
            parameters: values
        )
    }

    public static func randomized(
        modelType: String
    ) -> VoiceTuning {
        var values: [String: Double] = [:]
        for parameter in parameters(modelType: modelType) {
            values[parameter.key] = parameter.clamped(
                Double.random(in: parameter.range)
            )
        }
        return VoiceTuning(preset: .natural, parameters: values)
    }

    public static func nearestPreset(
        position: Double
    ) -> VoiceTuningPreset {
        switch position {
        case ..<0.25: .faithful
        case ..<0.75: .natural
        default: .expressive
        }
    }
}
