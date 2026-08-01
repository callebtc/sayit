import SwiftUI

struct ModelDisclosureRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isExpanded: Bool
    let count: Int

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DesignTokens.standardSpacing) {
                voiceMark

                VStack(alignment: .leading, spacing: 2) {
                    Text("Experimental models")
                        .fontWeight(.semibold)
                    Text(
                        "May be slow, glitchy, or produce lower-quality speech"
                    )
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
        .accessibilityLabel("Experimental models")
        .accessibilityValue(
            isExpanded
                ? "Expanded, \(count) models"
                : "Collapsed, \(count) models"
        )
        .accessibilityHint(
            isExpanded
                ? "Collapses the experimental model list"
                : "Shows the experimental model list"
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
                    .fill(.orange.gradient)
                    .frame(
                        width: 2.5,
                        height: barHeight(at: index)
                    )
            }
        }
        .frame(width: 28, height: 28)
        .background(.orange.opacity(0.1), in: .circle)
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
