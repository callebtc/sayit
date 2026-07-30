import SwiftUI

struct VoiceRibbonView: View {
    @State private var ribbonWidth = DesignTokens.popoverWidth
    @State private var smoothedProgress: Double = 0
    @State private var smoothedReveal: Double = 0
    let amplitudes: [Float]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let isPlaying: Bool
    let isBuffering: Bool
    let onSeek: (TimeInterval) -> Void

    private var progress: Double {
        guard generatedDuration > 0 else { return 0 }
        return min(max(elapsed / generatedDuration, 0), 1)
    }

    var body: some View {
        RibbonCanvas(
            amplitudes: amplitudes,
            progress: smoothedProgress,
            reveal: smoothedReveal
        )
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
            HStack(spacing: 5) {
                if isBuffering {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                }
                Text(elapsed.formattedDuration)
                    .contentTransition(.numericText(value: elapsed))
                Spacer()
                Text((estimatedDuration > 0 ? estimatedDuration : generatedDuration).formattedDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .offset(y: 13)
            .animation(DesignTokens.smoothAnimation, value: isBuffering)
        }
        .padding(.bottom, 13)
        .onChange(of: progress, initial: true) { oldValue, newValue in
            let isJump = newValue < oldValue || abs(newValue - oldValue) > 0.03
            if isPlaying, !isJump {
                let target = min(newValue + (newValue - oldValue), 1)
                withAnimation(.linear(duration: 0.1)) {
                    smoothedProgress = target
                }
            } else {
                withAnimation(.smooth(duration: isJump ? 0.4 : 0.25)) {
                    smoothedProgress = newValue
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            guard !playing else { return }
            withAnimation(.smooth(duration: 0.2)) {
                smoothedProgress = progress
            }
        }
        .onChange(of: amplitudes.count, initial: true) { oldValue, newValue in
            if newValue <= oldValue {
                smoothedReveal = Double(newValue)
            } else {
                withAnimation(.easeOut(duration: 0.55)) {
                    smoothedReveal = Double(newValue)
                }
            }
        }
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

private struct RibbonCanvas: View, Animatable {
    var amplitudes: [Float]
    var progress: Double
    var reveal: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, reveal) }
        set {
            progress = newValue.first
            reveal = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let values = amplitudes.isEmpty ? [Float(0)] : amplitudes
            let spacing = size.width / Double(max(values.count - 1, 1))
            let maximum = max(values.max() ?? 0, 0.0001)
            let revealed = min(reveal, Double(values.count))
            var pending = Path()
            var background = Path()
            var played = Path()

            for (index, amplitude) in values.enumerated() {
                let x = Double(index) * spacing
                let revealFraction = min(max(revealed - Double(index), 0), 1)
                let normalized = Double(amplitude / maximum)
                let fullHeight = max(1.5, normalized * (size.height * 0.44))
                let halfHeight = 1.5 + (fullHeight - 1.5) * revealFraction
                if x <= size.width * progress, revealFraction > 0.5 {
                    played.move(to: CGPoint(x: x, y: midY - halfHeight))
                    played.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                } else if revealFraction > 0.5 {
                    background.move(to: CGPoint(x: x, y: midY - halfHeight))
                    background.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                } else {
                    pending.move(to: CGPoint(x: x, y: midY - halfHeight))
                    pending.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                }
            }
            context.stroke(
                pending,
                with: .color(.primary.opacity(0.07)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                background,
                with: .color(.primary.opacity(0.18)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                played,
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
    }
}
