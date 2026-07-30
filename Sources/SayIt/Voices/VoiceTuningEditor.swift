import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceTuningEditor: View {
    let model: ModelDescriptor
    @Binding var tuning: VoiceTuning
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Refinement", selection: $tuning.preset) {
                ForEach(VoiceTuningPreset.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: tuning.preset) {
                resetDefaults()
            }

            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(parameters, id: \.key) { parameter in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(parameter.title)
                                Spacer()
                                Text(
                                    value(parameter.key).formatted(
                                        .number.precision(.fractionLength(
                                            parameter.step >= 1 ? 0 : 2
                                        ))
                                    )
                                )
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: binding(parameter.key),
                                in: parameter.range,
                                step: parameter.step
                            )
                            .accessibilityLabel(parameter.title)
                        }
                    }
                    Button("Reset Defaults", action: resetDefaults)
                }
                .padding(.top, 8)
            }
        }
        .task {
            if tuning.parameters.isEmpty {
                resetDefaults()
            }
        }
    }

    private var parameters: [Parameter] {
        switch model.modelType.lowercased() {
        case "qwen3_tts":
            [
                Parameter("temperature", "Temperature", 0.2...1.2, 0.05),
                Parameter("topP", "Top P", 0.5...1, 0.05),
                Parameter("topK", "Top K", 0...100, 1),
                Parameter("repetitionPenalty", "Repetition", 0.9...1.5, 0.05)
            ]
        case "fish_speech":
            [
                Parameter("temperature", "Temperature", 0.2...1.2, 0.05),
                Parameter("topP", "Top P", 0.5...1, 0.05),
                Parameter("topK", "Top K", 0...100, 1)
            ]
        case "chatterbox":
            [
                Parameter("temperature", "Temperature", 0.2...1.2, 0.05),
                Parameter("cfg", "CFG", 0...1, 0.05),
                Parameter("exaggeration", "Exaggeration", 0...1, 0.05)
            ]
        case "omnivoice":
            [
                Parameter("diffusionSteps", "Diffusion Steps", 8...64, 1),
                Parameter("guidance", "Guidance", 1...5, 0.1),
                Parameter("positionTemperature", "Position Temperature", 0...10, 0.25),
                Parameter("classTemperature", "Class Temperature", 0...2, 0.05),
                Parameter("timeShift", "Time Shift", 0...1, 0.02)
            ]
        default:
            []
        }
    }

    private func binding(_ key: String) -> Binding<Double> {
        Binding(
            get: { value(key) },
            set: { tuning.parameters[key] = $0 }
        )
    }

    private func value(_ key: String) -> Double {
        tuning.parameters[key] ?? defaults[key] ?? 0
    }

    private func resetDefaults() {
        tuning.parameters = defaults
    }

    private var defaults: [String: Double] {
        VoiceTuningDefaults.values(
            modelType: model.modelType,
            preset: tuning.preset
        )
    }
}

enum VoiceTuningDefaults {
    static func values(
        modelType: String,
        preset: VoiceTuningPreset
    ) -> [String: Double] {
        switch (modelType.lowercased(), preset) {
        case ("qwen3_tts", .faithful):
            ["temperature": 0.45, "topP": 0.75, "topK": 20, "repetitionPenalty": 1.3]
        case ("qwen3_tts", .natural):
            ["temperature": 0.65, "topP": 0.9, "topK": 40, "repetitionPenalty": 1.2]
        case ("qwen3_tts", .expressive):
            ["temperature": 0.85, "topP": 0.95, "topK": 50, "repetitionPenalty": 1.2]
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
            ["diffusionSteps": 48, "guidance": 2.8, "positionTemperature": 3.5, "classTemperature": 0, "timeShift": 0.08]
        case ("omnivoice", .natural):
            ["diffusionSteps": 32, "guidance": 2, "positionTemperature": 5, "classTemperature": 0, "timeShift": 0.1]
        case ("omnivoice", .expressive):
            ["diffusionSteps": 28, "guidance": 1.6, "positionTemperature": 7, "classTemperature": 0.35, "timeShift": 0.18]
        default:
            [:]
        }
    }
}

private extension VoiceTuningEditor {
    struct Parameter {
        let key: String
        let title: String
        let range: ClosedRange<Double>
        let step: Double

        init(
            _ key: String,
            _ title: String,
            _ range: ClosedRange<Double>,
            _ step: Double
        ) {
            self.key = key
            self.title = title
            self.range = range
            self.step = step
        }
    }
}

private extension VoiceTuningPreset {
    var title: String {
        rawValue.capitalized
    }
}
