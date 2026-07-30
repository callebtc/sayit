import SwiftUI

struct VoiceLevelMeter: View {
    let level: Float
    let peak: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<18, id: \.self) { index in
                Capsule()
                    .fill(index < activeBars ? Color.accentColor : .secondary.opacity(0.2))
                    .frame(width: 6, height: barHeight(index))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(levelDescription)
    }

    private var activeBars: Int {
        min(max(Int(sqrt(max(level, 0)) * 24), 0), 18)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        10 + CGFloat(index % 5) * 4
    }

    private var levelDescription: String {
        if peak >= 0.995 { return "Too loud" }
        if level < 0.01 { return "Very quiet" }
        if level < 0.05 { return "Quiet" }
        return "Good"
    }
}
