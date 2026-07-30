import SayItCore
import SayItProtocol
import SwiftUI

struct VoicesSettingsView: View {
    @Environment(AppState.self) private var state
    @Bindable var settings: AppSettings

    @State private var selectedModelID = ModelID("")
    @State private var selection = VoiceSelection.automaticStable
    @State private var discoveryModel: ModelDescriptor?

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

                    if !isSelectedModelActive {
                        Button(
                            "Use \(model.displayName) for Speech",
                            action: selectModelForSpeech
                        )
                        .disabled(!isSelectedModelInstalled)
                    }
                }
            }

            Section {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Voices",
                        systemImage: "person.wave.2",
                        description: Text(
                            "Discover a voice you like, then save it here."
                        )
                    )
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
                            onRename: {
                                state.renameVoice(profile, name: $0)
                            },
                            onDelete: {
                                state.deleteVoice(profile)
                            }
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
               model.capabilities.supportsVoiceDiscovery {
                Section("Create") {
                    Button(
                        "Discover Voices…",
                        systemImage: "sparkles",
                        action: showDiscovery
                    )
                    .disabled(
                        !isSelectedModelInstalled
                            || state.serviceSnapshot?.activeJob != nil
                    )
                }
            }
        }
        .task {
            selectInitialModel()
        }
        .sheet(item: $discoveryModel) {
            VoiceDiscoveryView(model: $0)
        }
    }

    private var voiceModels: [ModelDescriptor] {
        state.models.filter { model in
            model.capabilities.presetVoices
                || model.capabilities.voiceCloning
                || model.capabilities.supportsVoiceDiscovery
                || state.voiceProfiles.contains {
                    $0.modelID == model.id.rawValue
                }
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

    private func selectModelForSpeech() {
        guard let model = selectedModel, isSelectedModelInstalled else {
            return
        }
        state.selectModel(model)
    }

    private func showDiscovery() {
        discoveryModel = selectedModel
    }
}
