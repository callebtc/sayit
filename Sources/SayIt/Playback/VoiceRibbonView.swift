import SwiftUI

struct VoiceRibbonView: View {
    @State private var ribbonWidth = DesignTokens.popoverWidth
    let amplitudes: [Float]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let values = amplitudes.isEmpty ? [Float(0)] : amplitudes
            let spacing = size.width / Double(max(values.count - 1, 1))
            let maximum = max(values.max() ?? 0, 0.0001)
            var background = Path()
            var played = Path()

            for (index, amplitude) in values.enumerated() {
                let x = Double(index) * spacing
                let normalized = Double(amplitude / maximum)
                let halfHeight = max(1.5, normalized * (size.height * 0.44))
                background.move(to: CGPoint(x: x, y: midY - halfHeight))
                background.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                let progress = generatedDuration > 0
                    ? elapsed / generatedDuration
                    : 0
                if x <= size.width * progress {
                    played.move(to: CGPoint(x: x, y: midY - halfHeight))
                    played.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                }
            }
            context.stroke(
                background,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
            context.opacity = 1
            context.stroke(
                played,
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        .foregroundStyle(.tertiary)
        .frame(height: DesignTokens.ribbonHeight)
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            ribbonWidth = newWidth
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let fraction = min(
                        max(value.location.x / max(ribbonWidth, 1), 0),
                        1
                    )
                    onSeek(generatedDuration * fraction)
                }
        )
        .overlay(alignment: .bottom) {
            HStack {
                Text(elapsed.formattedDuration)
                Spacer()
                Text((estimatedDuration > 0 ? estimatedDuration : generatedDuration).formattedDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .offset(y: 13)
        }
        .padding(.bottom, 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(elapsed.formattedDuration) of \(generatedDuration.formattedDuration)"
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSeek(min(elapsed + 15, generatedDuration))
            case .decrement:
                onSeek(max(elapsed - 15, 0))
            @unknown default:
                break
            }
        }
    }
}
