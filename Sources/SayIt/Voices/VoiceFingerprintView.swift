import SwiftUI

struct VoiceFingerprintView: View {
    let values: [Float]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let barWidth = size.width / Double(values.count)
            for (index, value) in values.enumerated() {
                let height = max(Double(value) * size.height, 2)
                let rectangle = CGRect(
                    x: Double(index) * barWidth,
                    y: (size.height - height) / 2,
                    width: max(barWidth - 2, 1),
                    height: height
                )
                context.fill(
                    Path(roundedRect: rectangle, cornerRadius: 2),
                    with: .color(.accentColor)
                )
            }
        }
        .frame(minWidth: 120, idealWidth: 180, maxWidth: 240, minHeight: 32)
        .accessibilityHidden(true)
    }
}
