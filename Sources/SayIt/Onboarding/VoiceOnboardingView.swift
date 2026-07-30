import SayItCore
import SwiftUI

struct VoiceOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var isChoosingAnotherModel = false

    var body: some View {
        OnboardingPage(
            symbol: "waveform.circle",
            title: "Choose a voice",
            subtitle: "A compact, multilingual voice model, recommended for this Mac."
        ) {
            VStack(spacing: DesignTokens.standardSpacing) {
                if let model = recommendedModel {
                    RecommendedOnboardingModelView(model: model)
                }

                Button(
                    "Choose another model…",
                    systemImage: "list.bullet",
                    action: showModelPicker
                )
                .popover(isPresented: $isChoosingAnotherModel) {
                    OnboardingModelPickerView(
                        recommendedModelID: recommendedModel?.id
                    )
                    .environment(state)
                }

                if let progress = state.downloadProgress,
                   progress.modelID != recommendedModel?.id {
                    OnboardingModelDownloadView(
                        progress: progress,
                        modelName: modelName(for: progress.modelID)
                    )
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom))
                    )
                }
            }
            .animation(
                DesignTokens.smoothAnimation,
                value: showsExternalDownload
            )
        }
    }

    private var showsExternalDownload: Bool {
        guard let progress = state.downloadProgress else { return false }
        return progress.modelID != recommendedModel?.id
    }

    private var recommendedModel: ModelDescriptor? {
        state.models.first { $0.stability == .recommended }
    }

    private func showModelPicker() {
        isChoosingAnotherModel = true
    }

    private func modelName(for id: ModelID) -> String {
        state.models.first { $0.id == id }?.displayName ?? "voice model"
    }
}
