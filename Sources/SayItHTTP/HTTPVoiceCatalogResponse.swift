import SayItProtocol

struct HTTPVoiceCatalogResponse: Codable, Sendable {
    let profiles: [VoiceProfileSnapshot]
    let models: [HTTPVoiceModelModes]
}

struct HTTPVoiceModelModes: Codable, Sendable {
    let modelID: String
    let available: Bool
    let supportedSelectionModes: [String]
    let presets: [String]
    let currentSelection: VoiceSelection?

    init(
        model: ModelSnapshot,
        installedModelIDs: Set<String>,
        currentSelection: VoiceSelection?
    ) {
        modelID = model.id
        available = installedModelIDs.contains(model.id)
        var modes: [String] = []
        if model.hasPresetVoices {
            modes.append("preset")
        }
        if model.supportsVoiceDiscovery {
            modes.append("automaticStable")
        }
        if model.supportsVoiceDiscovery || model.supportsVoiceCloning {
            modes.append("profile")
        }
        if model.supportsRandomVoiceSampling {
            modes.append("randomPerParagraph")
        }
        supportedSelectionModes = modes
        presets = model.voices
        self.currentSelection = currentSelection
    }
}
