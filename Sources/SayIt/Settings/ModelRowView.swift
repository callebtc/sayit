import SayItCore
import SwiftUI

struct ModelRowView: View {
    @Environment(AppState.self) private var state
    @State private var isConfirmingDelete = false
    @State private var isConfirmingMemoryUse = false
    let model: ModelDescriptor
    var selectAfterDownload = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.standardSpacing) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.semibold)
                    if model.stability == .recommended {
                        SayItBadge(title: "Recommended")
                    } else if model.stability == .experimental {
                        SayItBadge(title: "Experimental", tint: .orange)
                    } else if model.stability == .unavailable {
                        SayItBadge(title: "Unavailable", tint: .secondary)
                    }
                }
                Text(modelSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let note = model.experience?.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if let installError = state.modelInstallError,
                   installError.modelID == model.id {
                    Label(
                        installError.message,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Spacer()

            if !model.isSelectable
                && !state.installedModelIDs.contains(model.id) {
                Text("Unavailable in this version")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if state.requestedModelInstallID == model.id
                || state.downloadProgress?.modelID == model.id {
                ModelDownloadControls(model: model, onRetry: downloadModel)
            } else if state.installedModelIDs.contains(model.id) {
                if !model.isSelectable {
                    Text("Unavailable in this version")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if state.settings.activeModelID == model.id {
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
                if model.isSelectable,
                   state.modelsWithVoiceUpdates.contains(model.id) {
                    Button("Update Voices", action: downloadModel)
                        .disabled(state.modelInstallIsBusy)
                }
                Button(
                    "Delete",
                    systemImage: "trash",
                    action: confirmDelete
                )
                .labelStyle(.iconOnly)
                .buttonStyle(CircularIconButtonStyle())
                .foregroundStyle(.secondary)
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
                if state.modelInstallError?.modelID == model.id {
                    Button(
                        "Retry",
                        systemImage: "arrow.clockwise",
                        action: downloadModel
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircularIconButtonStyle())
                    .help("Retry the download")
                } else {
                    Button("Download", action: downloadModel)
                        .buttonStyle(.borderedProminent)
                        .disabled(state.modelInstallIsBusy)
                }
            }
        }
        .padding(.vertical, DesignTokens.compactSpacing)
        .disabled(!state.isServiceOnline)
        .help(
            state.isServiceOnline
                ? ""
                : "The background service must be connected to manage models."
        )
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        if !model.isSelectable {
            "lock.circle"
        } else if state.installedModelIDs.contains(model.id) {
            "checkmark.circle.fill"
        } else {
            "arrow.down.circle"
        }
    }

    private var statusColor: Color {
        if model.isSelectable && state.installedModelIDs.contains(model.id) {
            .green
        } else {
            .secondary
        }
    }

    private var modelSummary: String {
        let languageCount = model.languages.count
        let languages = languageCount == 1
            ? model.languages[0].uppercased()
            : "\(languageCount) languages"
        if let experience = model.experience {
            return "\(experience.size.displayName) model · "
                + "\(experience.speed.displayName) · \(languages)"
        }
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
        state.installModel(
            model.id,
            selectAfterInstallation: selectAfterDownload
        )
    }
}
