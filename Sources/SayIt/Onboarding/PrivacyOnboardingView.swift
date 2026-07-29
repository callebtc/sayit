import SwiftUI

struct PrivacyOnboardingView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: DesignTokens.compactSpacing) {
                Text("Private by design")
                    .font(.largeTitle)
                    .fontDesign(.rounded)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Your text and generated audio stay on this Mac. Say It connects only when you download a model or check for an update."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                Label("No cloud speech service", systemImage: "icloud.slash")
                Label("No passive clipboard monitoring", systemImage: "doc.on.clipboard")
                Label("No analytics or microphone access", systemImage: "waveform.slash")
            }
        }
        .padding(32)
    }
}
