import SayItCore
import SwiftUI

struct ModelRowView: View {
    @Environment(AppState.self) private var state
    @State private var isConfirmingDelete = false
    @State private var isConfirmingMemoryUse = false
    let model: ModelDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.standardSpacing) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusStyle)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .bold()
                    if model.stability == .recommended {
                        Text("Recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.stability == .experimental {
                        Text("Experimental")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(modelSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(
                        state.downloadByteCount(for: model),
                        format: .byteCount(style: .file)
                    )
                    Text("·")
                    Text(model.license.identifier)
                    Text("·")
                    Text(suitabilityLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if model.capabilities.requiresReferenceAudio {
                Text("Requires voice profiles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if state.installedModelIDs.contains(model.id) {
                if state.settings.activeModelID == model.id {
                    Label("Selected", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use", action: useModel)
                    .confirmationDialog(
                        "Use \(model.displayName)?",
                        isPresented: $isConfirmingMemoryUse
                    ) {
                        Button("Use Model", action: selectModel)
                    } message: {
                        Text(
                            "Its estimated peak memory exceeds 70% of this Mac’s physical memory. Other apps may become less responsive."
                        )
                    }
                }
                Button(
                    "Delete",
                    systemImage: "trash",
                    action: confirmDelete
                )
                .labelStyle(.iconOnly)
                .confirmationDialog(
                    "Delete \(model.displayName)?",
                    isPresented: $isConfirmingDelete
                ) {
                    Button(
                        "Delete Model",
                        role: .destructive,
                        action: deleteModel
                    )
                } message: {
                    Text("History audio is not affected.")
                }
            } else {
                Button("Download", action: downloadModel)
                .buttonStyle(.borderedProminent)
                .disabled(state.downloadProgress != nil)
            }
        }
        .padding(.vertical, DesignTokens.compactSpacing)
        .disabled(!state.isServiceOnline)
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        if state.installedModelIDs.contains(model.id) {
            "checkmark.circle.fill"
        } else if model.capabilities.requiresReferenceAudio {
            "lock.circle"
        } else {
            "arrow.down.circle"
        }
    }

    private var statusStyle: HierarchicalShapeStyle {
        .secondary
    }

    private var modelSummary: String {
        let languageCount = model.languages.count
        let languages = languageCount == 1
            ? model.languages[0].uppercased()
            : "\(languageCount) languages"
        return "\(model.family) · \(model.quantization) · \(languages)"
    }

    private var suitabilityLabel: String {
        switch HardwareAdvisor().suitability(for: model) {
        case .recommended: "Recommended for this Mac"
        case .mayBeSlow: "May be slow"
        case .notRecommended: "Not recommended for this Mac"
        }
    }

    private var requiresMemoryConfirmation: Bool {
        Double(model.estimatedPeakMemoryBytes)
            > Double(ProcessInfo.processInfo.physicalMemory) * 0.7
    }

    private func useModel() {
        if requiresMemoryConfirmation {
            isConfirmingMemoryUse = true
        } else {
            selectModel()
        }
    }

    private func selectModel() {
        state.selectModel(model)
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func deleteModel() {
        state.removeModel(model)
    }

    private func downloadModel() {
        state.installModel(model.id)
    }
}
