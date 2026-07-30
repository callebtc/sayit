import SwiftUI

struct PrivacyOnboardingView: View {
    var body: some View {
        OnboardingPage(
            symbol: "lock.shield",
            title: "Private by design",
            subtitle: "Your text and generated audio stay on this Mac. Say It connects only when you download a model or check for an update."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                Label("No cloud speech service", systemImage: "icloud.slash")
                Label(
                    "No passive clipboard monitoring",
                    systemImage: "doc.on.clipboard"
                )
                Label(
                    "No analytics or passive microphone listening",
                    systemImage: "mic.slash"
                )
            }
            .labelStyle(.onboardingFeature)
            .padding(.top, DesignTokens.compactSpacing)
        }
    }
}
