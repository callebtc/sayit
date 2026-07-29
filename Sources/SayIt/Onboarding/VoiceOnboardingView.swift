import SayItCore
import SwiftUI

struct VoiceOnboardingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 22) {
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
                LabeledContent {
                    Text(
                        state.downloadByteCount(for: model),
                        format: .byteCount(style: .file)
                    )
                        .monospacedDigit()
                } label: {
                    Label("\(model.displayName) · \(model.defaultVoice ?? "")", systemImage: "speaker.wave.2")
                }
                .frame(maxWidth: 380)

                if state.installedModelIDs.contains(model.id) {
                    HStack {
                        Label("Installed and verified", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Play sample", action: state.speakSample)
                    }
                } else if let progress = state.downloadProgress {
                    DownloadStatusView(progress: progress)
                        .frame(maxWidth: 380)
                } else {
                    Button(
                        "Download Kokoro",
                        action: downloadRecommendedModel
                    )
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
    }

    private var recommendedModel: ModelDescriptor? {
        state.models.first { $0.stability == .recommended }
    }

    private func downloadRecommendedModel() {
        guard let model = recommendedModel else { return }
        state.installModel(model.id)
    }
}
