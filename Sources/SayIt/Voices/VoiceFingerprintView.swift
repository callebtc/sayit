import SwiftUI

struct VoiceFingerprintView: View {
    let values: [Float]
    var isActive = false

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let midY = size.height / 2
            let spacing = size.width / Double(values.count - 1)
            let maximum = max(values.max() ?? 0, 0.0001)
            var path = Path()
            for (index, value) in values.enumerated() {
                let normalized = Double(value / maximum)
                let halfHeight = max(
                    1.5,
                    normalized * Double(size.height) * 0.46
                )
                let x = Double(index) * spacing
                path.move(to: CGPoint(x: x, y: midY - halfHeight))
                path.addLine(to: CGPoint(x: x, y: midY + halfHeight))
            }
            context.stroke(
                path,
                with: isActive
                    ? .color(.accentColor)
                    : .color(.primary.opacity(0.18)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        .frame(minHeight: 24)
        .animation(DesignTokens.smoothAnimation, value: isActive)
        .accessibilityHidden(true)
    }
}
