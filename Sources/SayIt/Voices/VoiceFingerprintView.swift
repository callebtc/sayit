import SwiftUI

struct VoiceFingerprintView: View {
    let values: [Float]
    var isActive = false

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let barWidth = size.width / Double(values.count)
            for (index, value) in values.enumerated() {
                let height = max(Double(value) * size.height, 2.5)
                let rectangle = CGRect(
                    x: Double(index) * barWidth,
                    y: (size.height - height) / 2,
                    width: max(barWidth - 2, 1),
                    height: height
                )
                context.fill(
                    Path(roundedRect: rectangle, cornerRadius: 2),
                    with: .color(.accentColor.opacity(opacity(for: value)))
                )
            }
        }
        .frame(minHeight: 24)
        .animation(DesignTokens.smoothAnimation, value: isActive)
        .accessibilityHidden(true)
    }

    private func opacity(for value: Float) -> Double {
        let base = 0.45 + Double(min(max(value, 0), 1)) * 0.55
        return isActive ? base : base * 0.75
    }
}
