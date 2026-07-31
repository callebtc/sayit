import SayItCore
import SayItProtocol
import SwiftUI

struct VoiceTuningEditor: View {
    let model: ModelDescriptor
    @Binding var tuning: VoiceTuning
    @State private var showsAdvanced: Bool

    init(
        model: ModelDescriptor,
        tuning: Binding<VoiceTuning>,
        advancedExpanded: Bool = false
    ) {
        self.model = model
        _tuning = tuning
        _showsAdvanced = State(initialValue: advancedExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Picker("Refinement", selection: $tuning.preset) {
                ForEach(VoiceTuningPreset.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tuning.preset) {
                resetDefaults()
            }

            HStack(spacing: DesignTokens.compactSpacing) {
                Button {
                    showsAdvanced.toggle()
                } label: {
                    HStack(spacing: DesignTokens.compactSpacing) {
                        Text("Advanced")
                            .font(.callout.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsAdvanced ? 0 : -90))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Spacer()
                if showsAdvanced {
                    Button("Reset Defaults", action: resetDefaults)
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                }
            }

            if showsAdvanced, !parameters.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                    ForEach(parameters, id: \.key) { parameter in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(parameter.title)
                                    .font(.callout)
                                Spacer()
                                Text(
                                    value(parameter.key).formatted(
                                        .number.precision(.fractionLength(
                                            parameter.step >= 1 ? 0 : 2
                                        ))
                                    )
                                )
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: binding(parameter.key),
                                in: parameter.range,
                                step: parameter.step
                            )
                            .controlSize(.small)
                            .accessibilityLabel(parameter.title)
                        }
                    }
                }
                .padding(.top, DesignTokens.compactSpacing)
            }
        }
        .task {
            if tuning.parameters.isEmpty {
                resetDefaults()
            }
        }
    }

    private var parameters: [VoiceTuningParameter] {
        VoiceTuningSpace.parameters(modelType: model.modelType)
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
        VoiceTuningSpace.defaults(
            modelType: model.modelType,
            preset: tuning.preset
        )
    }
}

private extension VoiceTuningPreset {
    var title: String {
        rawValue.capitalized
    }
}
