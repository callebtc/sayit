import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .bold()
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
        }
        .scrollContentBackground(.visible)
    }
}
