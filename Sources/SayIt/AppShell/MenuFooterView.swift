import AppKit
import SayItCore
import SayItProtocol
import SwiftUI

struct MenuFooterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            modelMenu
            Button("Settings…", action: openSettingsWindow)
                .buttonStyle(.sayItInline)
                .fixedSize()
                .layoutPriority(1)
            Button("Quit", action: state.quit)
                .buttonStyle(.sayItInline)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(.callout)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(installedModels) { model in
                Button {
                    state.switchPlaybackModel(model)
                } label: {
                    if model.id == displayedModelID {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "shippingbox")
                    .imageScale(.small)
                    .fixedSize()
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .disabled(installedModels.isEmpty)
        .accessibilityLabel(modelLabel)
        .help(
            modelLabel + "\n" + (displayedModelID == state.settings.activeModelID
                ? "Switch the speech model"
                : "Model used for this audio. Pick another model to re-synthesize.")
        )
    }

    private var displayedModelID: ModelID {
        if state.playback.state != .idle,
           let playbackModelID = state.playback.modelID {
            return playbackModelID
        }
        return state.settings.activeModelID
    }

    private var modelLabel: String {
        Self.modelLabel(
            for: displayedModelID,
            models: state.models,
            settings: state.settings,
            profiles: state.voiceProfiles
        )
    }

    static func modelLabel(
        for modelID: ModelID,
        models: [ModelDescriptor],
        settings: AppSettings,
        profiles: [VoiceProfileSnapshot]
    ) -> String {
        let model = models.first { $0.id == modelID }
        let name = model?.displayName ?? modelID.rawValue
        guard modelID == settings.activeModelID else { return name }

        let voiceName: String?
        switch settings.activeVoiceSelection {
        case .preset(let voice):
            voiceName = voice.isEmpty ? nil : voice
        case .profile(let id):
            voiceName = profiles.first {
                $0.id == id && $0.modelID == modelID.rawValue
            }?.displayName
        case .automaticStable:
            if model?.capabilities.supportsRandomVoiceSampling == true {
                voiceName = "Random voice"
            } else if model?.capabilities.voiceDescription == true {
                voiceName = "Custom description"
            } else {
                voiceName = "Automatic"
            }
        case .randomPerParagraph:
            voiceName = "Random voice every paragraph"
        }
        guard let voiceName, !voiceName.isEmpty else { return name }
        return "\(name) · \(voiceName)"
    }

    private var installedModels: [ModelDescriptor] {
        state.models.filter { state.installedModelIDs.contains($0.id) }
    }

    private func openSettingsWindow() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            WindowActivator.prepareForWindowPresentation()
            openWindow(id: AppWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
