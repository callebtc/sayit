import AppKit
import SayItCore
import SwiftUI

struct MenuFooterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var showSettings

    var body: some View {
        HStack(spacing: DesignTokens.compactSpacing) {
            modelMenu
            Spacer()
            Button("Settings…", action: openSettingsWindow)
                .buttonStyle(.sayItInline)
            Button("Quit", action: state.quit)
                .buttonStyle(.sayItInline)
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
                Text(modelLabel)
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(installedModels.isEmpty)
        .help(
            displayedModelID == state.settings.activeModelID
                ? "Switch the speech model"
                : "Model used for this audio. Pick another model to re-synthesize."
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
        let name = state.models.first(where: {
            $0.id == displayedModelID
        })?.displayName ?? displayedModelID.rawValue
        guard displayedModelID == state.settings.activeModelID,
              !state.settings.activeVoice.isEmpty else {
            return name
        }
        return "\(name) · \(state.settings.activeVoice)"
    }

    private var installedModels: [ModelDescriptor] {
        state.models.filter { state.installedModelIDs.contains($0.id) }
    }

    private func openSettingsWindow() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            WindowActivator.prepareForWindowPresentation()
            showSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
