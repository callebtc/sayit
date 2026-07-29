import SayItCore
import SwiftUI

struct OnboardingModelPickerView: View {
    @Environment(AppState.self) private var state
    let recommendedModelID: ModelID?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                Text("Other voice models")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Compare download size, license, languages, and expected performance."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.generousSpacing)

            Divider()

            List(alternativeModels) { model in
                ModelRowView(
                    model: model,
                    selectAfterDownload: true
                )
            }
            .overlay {
                if alternativeModels.isEmpty {
                    ContentUnavailableView(
                        "No other models available",
                        systemImage: "speaker.slash"
                    )
                }
            }
        }
        .frame(width: 520, height: 320)
    }

    private var alternativeModels: [ModelDescriptor] {
        state.models.filter { $0.id != recommendedModelID }
    }
}
