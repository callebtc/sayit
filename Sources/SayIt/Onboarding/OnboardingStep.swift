import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case privacy
    case voice
    case anywhere

    var id: Self { self }
}
