import SayItCore
import SwiftUI

struct VoiceOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var isChoosingAnotherModel = false

    var body: some View {
        VStack(spacing: DesignTokens.generousSpacing) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: DesignTokens.compactSpacing) {
                Text("Choose a voice")
                    .font(.largeTitle)
                    .fontDesign(.rounded)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text("Kokoro is compact, multilingual, and recommended for this Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if let model = recommendedModel {
                RecommendedOnboardingModelView(model: model)
            }

            Button(
                "Choose another model…",
                systemImage: "list.bullet",
                action: showModelPicker
            )
            .buttonStyle(.link)
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
        .padding(32)
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
