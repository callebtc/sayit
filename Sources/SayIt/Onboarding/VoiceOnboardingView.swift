import SayItCore
import SwiftUI

struct VoiceOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var isChoosingAnotherModel = false

    var body: some View {
        OnboardingPage(
            symbol: "waveform.circle",
            title: "Choose a voice",
            subtitle: "Kokoro is compact, multilingual, and recommended for this Mac."
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
                }
            }
        }
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
