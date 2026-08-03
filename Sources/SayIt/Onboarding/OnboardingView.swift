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
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            ZStack {
                OnboardingProgressView(currentStep: step)
                HStack {
                    if step != .privacy {
                        Button("Back", action: goBack)
                            .controlSize(.large)
                    }
                    Spacer()
                    Button(nextButtonTitle, action: goForward)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DesignTokens.generousSpacing)
            .background(.bar)
        }
        .animation(DesignTokens.quickAnimation, value: step)
        .frame(width: 560, height: 500)
        .onDisappear(perform: state.onboardingWindowDidClose)
    }

    private var nextButtonTitle: String {
        if step == .anywhere {
            "Finish"
        } else if step == .voice && state.installedModelIDs.isEmpty {
            "Continue Without a Model"
        } else {
            "Continue"
        }
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
