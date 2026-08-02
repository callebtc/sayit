import SwiftUI

struct ModelDisclosureRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isExpanded: Bool
    let count: Int
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DesignTokens.standardSpacing) {
                voiceMark

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: DesignTokens.standardSpacing)

                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            isExpanded
                ? "Expanded, \(count) models"
                : "Collapsed, \(count) models"
        )
        .accessibilityHint(
            isExpanded
                ? "Collapses the \(title.lowercased()) list"
                : "Shows the \(title.lowercased()) list"
        )
        .animation(
            reduceMotion ? nil : DesignTokens.springAnimation,
            value: isExpanded
        )
    }

    private var voiceMark: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(tint.gradient)
                    .frame(
                        width: 2.5,
                        height: barHeight(at: index)
                    )
            }
        }
        .frame(width: 28, height: 28)
        .background(tint.opacity(0.1), in: .circle)
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> Double {
        guard isExpanded else { return 4 }
        return [8, 15, 10][index]
    }

    private func toggle() {
        isExpanded.toggle()
    }
}
