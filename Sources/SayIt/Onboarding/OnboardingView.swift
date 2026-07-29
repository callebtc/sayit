import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = OnboardingStep.privacy

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .privacy:
                    PrivacyOnboardingView()
                case .voice:
                    VoiceOnboardingView()
                case .anywhere:
                    AnywhereOnboardingView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if step != .privacy {
                    Button("Back", action: goBack)
                }
                Spacer()
                OnboardingProgressView(currentStep: step)
                Spacer()
                Button(nextButtonTitle, action: goForward)
                    .buttonStyle(.borderedProminent)
                    .disabled(step == .voice && state.installedModelIDs.isEmpty)
            }
            .padding(DesignTokens.generousSpacing)
        }
        .frame(width: 540, height: 430)
        .onDisappear(perform: state.onboardingWindowDidClose)
    }

    private var nextButtonTitle: String {
        step == .anywhere ? "Finish" : "Continue"
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else {
            return
        }
        step = previous
    }

    private func goForward() {
        if step == .anywhere {
            state.finishOnboarding()
            dismissWindow(id: AppWindowID.onboarding)
        } else if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            step = next
        }
    }
}
