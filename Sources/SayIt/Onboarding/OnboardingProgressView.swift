import SwiftUI

struct OnboardingProgressView: View {
    let currentStep: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(
                        step == currentStep
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue(
            "Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)"
        )
    }
}
