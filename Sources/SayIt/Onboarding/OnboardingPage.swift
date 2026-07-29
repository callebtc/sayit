import SwiftUI

struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: DesignTokens.compactSpacing) {
                Text(title)
                    .font(.largeTitle)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 430)
            }

            content

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }
}

struct OnboardingFeatureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .center)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

extension LabelStyle where Self == OnboardingFeatureLabelStyle {
    static var onboardingFeature: OnboardingFeatureLabelStyle {
        OnboardingFeatureLabelStyle()
    }
}
