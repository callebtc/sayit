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
                progressDots
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

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(item == step ? Color.accentColor : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue("Step \(step.rawValue + 1) of 3")
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
