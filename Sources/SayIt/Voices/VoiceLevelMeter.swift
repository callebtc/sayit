import SwiftUI

struct VoiceLevelMeter: View {
    let level: Float
    let peak: Float

    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 5, height: barHeight(index))
                    .opacity(index < activeBars ? 1 : 0.25)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .animation(.linear(duration: 0.08), value: activeBars)
        .animation(DesignTokens.quickAnimation, value: isTooLoud)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(levelDescription)
    }

    private var activeBars: Int {
        let scaled = Double(max(level, 0)).squareRoot() * Double(barCount + 6)
        return min(max(Int(scaled), 0), barCount)
    }

    private var isTooLoud: Bool {
        peak >= 0.995
    }

    private func barColor(for index: Int) -> Color {
        guard index < activeBars else { return .secondary.opacity(0.35) }
        if isTooLoud, index >= barCount - 4 { return .red }
        if index >= barCount - 6 { return .orange }
        return .accentColor
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let wave = sin(Double(index) / Double(barCount) * .pi)
        return 8 + CGFloat(wave) * 14
    }

    private var levelDescription: String {
        if peak >= 0.995 { return "Too loud" }
        if level < 0.01 { return "Very quiet" }
        if level < 0.05 { return "Quiet" }
        return "Good"
    }
}
