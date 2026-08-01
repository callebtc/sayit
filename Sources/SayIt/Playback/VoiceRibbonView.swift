import SwiftUI

struct VoiceRibbonView: View {
    @State private var ribbonWidth = DesignTokens.popoverWidth
    @State private var smoothedProgress: Double = 0
    @State private var smoothedGeneration: Double = 0
    let amplitudes: [Float]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let isPlaying: Bool
    let isBuffering: Bool
    let onSeek: (TimeInterval) -> Void

    private var totalDuration: TimeInterval {
        max(estimatedDuration, generatedDuration)
    }

    private var progress: Double {
        guard generatedDuration > 0 else { return 0 }
        return min(max(elapsed / generatedDuration, 0), 1)
    }

    private var generation: Double {
        guard totalDuration > 0 else { return amplitudes.isEmpty ? 0 : 1 }
        return min(max(generatedDuration / totalDuration, 0), 1)
    }

    private var isProcessing: Bool {
        generation < 0.999
    }

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 30.0, paused: !isProcessing)
        ) { timeline in
            RibbonCanvas(
                amplitudes: amplitudes,
                progress: smoothedProgress,
                generation: smoothedGeneration,
                phase: timeline.date.timeIntervalSinceReferenceDate
            )
        }
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
                    let generatedWidth = max(ribbonWidth * generation, 1)
                    let fraction = min(
                        max(value.location.x / generatedWidth, 0),
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
        .onChange(of: generation, initial: true) { _, newValue in
            withAnimation(.smooth(duration: 0.6)) {
                smoothedGeneration = newValue
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
    var generation: Double
    var phase: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, generation) }
        set {
            progress = newValue.first
            generation = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let generationWidth = size.width * min(generation, 1)
            var played = Path()
            var live = Path()

            let values = amplitudes.isEmpty ? [Float(0)] : amplitudes
            let maximum = max(values.max() ?? 0, 0.0001)
            if generation > 0.001, generationWidth > 1 {
                let spacing = generationWidth / Double(max(values.count - 1, 1))
                for (index, amplitude) in values.enumerated() {
                    let x = Double(index) * spacing
                    guard x <= generationWidth else { break }
                    let normalized = Double(amplitude / maximum)
                    let halfHeight = max(
                        1.5,
                        normalized * (size.height * 0.44)
                    )
                    if x <= generationWidth * progress {
                        played.move(to: CGPoint(x: x, y: midY - halfHeight))
                        played.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                    } else {
                        live.move(to: CGPoint(x: x, y: midY - halfHeight))
                        live.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                    }
                }
            }

            var pending = Path()
            var shimmerSoft = Path()
            var shimmerBright = Path()
            if generation < 0.999 {
                let slotWidth = size.width / 96
                let pendingCount = max(
                    Int(((size.width - generationWidth) / slotWidth).rounded(.down)),
                    1
                )
                let sweep = (phase / 1.6)
                    .truncatingRemainder(dividingBy: 1.4) - 0.2
                for index in 0..<pendingCount {
                    let x = generationWidth + Double(index) * slotWidth
                    guard x <= size.width else { break }
                    let noise = placeholderAmplitude(index: index, phase: phase)
                    let halfHeight = max(
                        1.5,
                        noise * (size.height * 0.3)
                    )
                    let fraction = x / size.width
                    let shine = max(1 - abs(fraction - sweep) / 0.14, 0)
                    if shine > 0.66 {
                        shimmerBright.move(to: CGPoint(x: x, y: midY - halfHeight))
                        shimmerBright.addLine(
                            to: CGPoint(x: x, y: midY + halfHeight)
                        )
                    } else if shine > 0.33 {
                        shimmerSoft.move(to: CGPoint(x: x, y: midY - halfHeight))
                        shimmerSoft.addLine(
                            to: CGPoint(x: x, y: midY + halfHeight)
                        )
                    } else {
                        pending.move(to: CGPoint(x: x, y: midY - halfHeight))
                        pending.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                    }
                }
            }

            context.stroke(
                pending,
                with: .color(.primary.opacity(0.09)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                shimmerSoft,
                with: .color(.primary.opacity(0.16)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                shimmerBright,
                with: .color(.primary.opacity(0.26)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            context.stroke(
                live,
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

    private func placeholderAmplitude(index: Int, phase: Double) -> Double {
        let i = Double(index)
        let value = 0.45
            + 0.28 * sin(i * 0.83 + phase * 2.2)
            + 0.22 * sin(i * 0.31 - phase * 1.4)
            + 0.18 * sin(i * 1.71 + phase * 3.1)
        return min(max(value, 0.08), 1)
    }
}
