import SayItCore
import SayItProtocol
import SwiftUI
import UniformTypeIdentifiers

struct VoicesSettingsView: View {
    @Environment(AppState.self) private var state
    @Bindable var settings: AppSettings

    @State private var selectedModelID = ModelID("")
    @State private var selection = VoiceSelection.automaticStable
    @State private var discoveryModel: ModelDescriptor?
    @State private var cloneModel: ModelDescriptor?
    @State private var draggingProfileID: UUID?
    @State private var customizeProfile: VoiceProfileSnapshot?

    var body: some View {
        Form {
            Section("Voice model") {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(voiceModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: selectedModelID) {
                    synchronizeSelection()
                }

                if let model = selectedModel {
                    VoiceSelectionPicker(
                        selection: $selection,
                        model: model,
                        profiles: profiles
                    )
                    .onChange(of: selection) {
                        settings.voiceSelections[model.id.rawValue] = selection
                    }

                    if model.capabilities.voiceDescription,
                       selection == .automaticStable {
                        TextField(
                            "Custom voice description",
                            text: $settings.voiceDescription,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                    }

                    if !isSelectedModelActive {
                        Button(
                            selectedModelActionTitle(for: model),
                            action: activateSelectedModel
                        )
                        .disabled(
                            !state.isServiceOnline
                                || (!isSelectedModelInstalled
                                    && state.modelInstallIsBusy)
                        )
                    }
                }
            }

            Section {
                if profiles.isEmpty {
                    VStack(spacing: DesignTokens.compactSpacing) {
                        Image(systemName: "person.wave.2")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("No Saved Voices")
                            .font(.callout.weight(.medium))
                        Text("Discover a voice you like, then save it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.generousSpacing)
                } else {
                    ForEach(profiles) { profile in
                        VoiceProfileRow(
                            profile: profile,
                            isSelected: selection == .profile(profile.id),
                            isModelInstalled: isSelectedModelInstalled,
                            onSelect: {
                                selection = .profile(profile.id)
                                state.selectVoice(profile)
                            },
                            onTest: {
                                state.previewVoice(profile)
                            },
                            onCustomize: {
                                customizeProfile = profile
                            },
                            onRename: {
                                state.renameVoice(profile, name: $0)
                            },
                            onDelete: {
                                state.deleteVoice(profile)
                            },
                            makeDragItem: {
                                draggingProfileID = profile.id
                                return NSItemProvider(
                                    object: profile.id.uuidString as NSString
                                )
                            }
                        )
                        .onDrop(
                            of: [.text],
                            delegate: VoiceReorderDropDelegate(
                                target: profile,
                                profiles: profiles,
                                draggingProfileID: $draggingProfileID,
                                onMove: moveVoice
                            )
                        )
                    }
                }
            } header: {
                Text("My voices")
            } footer: {
                if !isSelectedModelInstalled {
                    Text(
                        "These voices stay in your library. Reinstall the model to use them."
                    )
                }
            }

            if let model = selectedModel,
               model.capabilities.supportsVoiceDiscovery
                || model.capabilities.voiceCloneRequirements != nil {
                Section {
                    if model.capabilities.supportsVoiceDiscovery {
                        creationRow(
                            title: "Discover Voices…",
                            subtitle: "Generate random voices and keep your favorites.",
                            icon: "sparkles",
                            action: showDiscovery
                        )
                    }
                    if model.capabilities.voiceCloneRequirements != nil {
                        creationRow(
                            title: "Clone a Voice…",
                            subtitle: "Record a short reference to create a voice profile.",
                            icon: "mic.badge.plus"
                        ) {
                            cloneModel = model
                        }
                    }
                } header: {
                    Text("Create")
                } footer: {
                    if isPlaybackBusy {
                        Label(
                            "Voice creation is available once playback is paused or stopped.",
                            systemImage: "speaker.wave.2"
                        )
                    } else if state.voiceStudio != nil {
                        Label(
                            "Another voice creation session is in progress.",
                            systemImage: "hourglass"
                        )
                    }
                }
            }
        }
        .task {
            selectInitialModel()
        }
        .sheet(item: $discoveryModel) {
            VoiceDiscoveryView(model: $0)
        }
        .sheet(item: $cloneModel) {
            VoiceCloneWizard(model: $0)
        }
        .sheet(item: $customizeProfile) { profile in
            if let model = state.models.first(where: {
                $0.id.rawValue == profile.modelID
            }) {
                VoiceCustomizeSheet(
                    profile: profile,
                    model: model,
                    isModelInstalled: state.installedModelIDs.contains(model.id)
                )
            }
        }
    }

    private var voiceModels: [ModelDescriptor] {
        state.models.filter { model in
            model.isSelectable
                && (model.capabilities.presetVoices
                    || model.capabilities.voiceCloning
                    || model.capabilities.supportsVoiceDiscovery
                    || state.voiceProfiles.contains {
                        $0.modelID == model.id.rawValue
                    })
        }
    }

    private var selectedModel: ModelDescriptor? {
        voiceModels.first { $0.id == selectedModelID }
    }

    private var profiles: [VoiceProfileSnapshot] {
        state.voiceProfiles.filter { $0.modelID == selectedModelID.rawValue }
    }

    private var isSelectedModelInstalled: Bool {
        state.installedModelIDs.contains(selectedModelID)
    }

    private var isSelectedModelActive: Bool {
        settings.activeModelID == selectedModelID
    }

    private func selectedModelActionTitle(
        for model: ModelDescriptor
    ) -> String {
        if isSelectedModelInstalled {
            "Use \(model.displayName) for Speech"
        } else {
            "Download and Use \(model.displayName) for Speech"
        }
    }

    private var isCreationUnavailable: Bool {
        !isSelectedModelInstalled
            || isPlaybackBusy
            || state.voiceStudio != nil
    }

    private var isPlaybackBusy: Bool {
        [
            PlaybackState.preparing,
            .buffering,
            .playing
        ].contains(state.playback.state)
    }

    private func selectInitialModel() {
        if voiceModels.contains(where: { $0.id == settings.activeModelID }) {
            selectedModelID = settings.activeModelID
        } else if let first = voiceModels.first {
            selectedModelID = first.id
        }
        synchronizeSelection()
    }

    private func synchronizeSelection() {
        guard let model = selectedModel else { return }
        selection = settings.voiceSelection(for: model.id)
            ?? model.defaultVoice.map(VoiceSelection.preset)
            ?? .automaticStable
    }

    private func activateSelectedModel() {
        guard let model = selectedModel else { return }
        if isSelectedModelInstalled {
            state.selectModel(model)
        } else {
            state.installModel(
                model.id,
                selectAfterInstallation: true
            )
        }
    }

    private func moveVoice(_ draggedID: UUID, before targetID: UUID) {
        var ids = profiles.map(\.id)
        guard let from = ids.firstIndex(of: draggedID),
              let to = ids.firstIndex(of: targetID),
              from != to else {
            return
        }
        ids.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        state.reorderVoices(modelID: selectedModelID.rawValue, orderedIDs: ids)
    }

    private func showDiscovery() {
        discoveryModel = selectedModel
    }

    private func creationRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.standardSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: .rect(cornerRadius: 7)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.sayItRow)
        .disabled(isCreationUnavailable)
    }
}

private struct VoiceReorderDropDelegate: DropDelegate {
    let target: VoiceProfileSnapshot
    let profiles: [VoiceProfileSnapshot]
    @Binding var draggingProfileID: UUID?
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggingProfileID,
              draggedID != target.id,
              profiles.contains(where: { $0.id == draggedID }) else {
            return
        }
        withAnimation(DesignTokens.smoothAnimation) {
            onMove(draggedID, target.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProfileID = nil
        return true
    }
}
