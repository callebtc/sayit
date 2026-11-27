import SwiftUI

struct VoiceRibbonView: View {
    nonisolated static let slotCount = 96
    nonisolated static let barLineWidth: Double = 2
    private nonisolated static let revealTransitionSlots: Double = 2.0

    @State private var ribbonWidth = DesignTokens.popoverWidth
    @State private var smoothedElapsed: TimeInterval = 0
    @State private var smoothedGeneratedDuration: TimeInterval = 0
    @State private var smoothedTotalDuration: TimeInterval = 0
    let amplitudes: [Float]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let isPlaying: Bool
    let isBuffering: Bool
    let isPresented: Bool
    let onSeek: (TimeInterval) -> Void

    private var totalDuration: TimeInterval {
        max(estimatedDuration, generatedDuration)
    }

    private var generation: Double {
        guard totalDuration > 0 else { return amplitudes.isEmpty ? 0 : 1 }
        return min(max(generatedDuration / totalDuration, 0), 1)
    }

    private var isProcessing: Bool {
        generation < 0.999
    }

    nonisolated static func shouldPauseTimeline(
        isPresented: Bool,
        isProcessing: Bool
    ) -> Bool {
        !isPresented || !isProcessing
    }

    nonisolated static func barCount(forWidth width: Double) -> Int {
        guard width > 0 else { return 0 }
        return max(min(slotCount, Int((width / 3.0).rounded(.down))), 1)
    }

    nonisolated static func barXPosition(
        slot: Int,
        count: Int,
        width: Double
    ) -> Double {
        guard count > 1 else { return width / 2 }
        let inset = barLineWidth / 2
        let usableWidth = max(width - barLineWidth, 0)
        return inset + (Double(slot) / Double(count - 1)) * usableWidth
    }

    nonisolated static func seekTime(
        forLocationX x: Double,
        width: Double,
        generatedDuration: TimeInterval,
        totalDuration: TimeInterval
    ) -> TimeInterval {
        guard generatedDuration > 0, totalDuration > 0 else { return 0 }
        let inset = barLineWidth / 2
        let usableWidth = max(width - barLineWidth, 1)
        let fraction = min(max((x - inset) / usableWidth, 0), 1)
        return min(fraction * totalDuration, generatedDuration)
    }

    nonisolated static func revealFactor(
        forSlot slot: Int,
        slotCount: Int,
        revealFraction: Double
    ) -> Double {
        guard slotCount > 0 else { return 0 }
        if revealFraction <= 0.0001 { return 0 }
        if revealFraction >= 0.999 { return 1 }
        let slotStart = Double(slot) / Double(slotCount)
        let transitionWidth = revealTransitionSlots / Double(slotCount)
        let frontier = revealFraction * (1 + transitionWidth)
        let linear = min(max((frontier - slotStart) / transitionWidth, 0), 1)
        return linear * linear * (3 - 2 * linear)
    }

    nonisolated static func slotAmplitude(
        slot: Int,
        slotCount: Int,
        amplitudes: [Float],
        actualGeneratedDuration: TimeInterval,
        displayTotalDuration: TimeInterval
    ) -> Float? {
        guard !amplitudes.isEmpty,
              slotCount > 0,
              slot >= 0,
              slot < slotCount else {
            return nil
        }

        let slotStartFraction = Double(slot) / Double(slotCount)
        let slotEndFraction = Double(slot + 1) / Double(slotCount)

        let sampleStart: Double
        let sampleEnd: Double
        if actualGeneratedDuration > 0, displayTotalDuration > 0 {
            let slotStartTime = slotStartFraction * displayTotalDuration
            guard slotStartTime < actualGeneratedDuration else { return nil }
            let slotEndTime = min(
                slotEndFraction * displayTotalDuration,
                actualGeneratedDuration
            )
            let scale = Double(amplitudes.count) / actualGeneratedDuration
            sampleStart = slotStartTime * scale
            sampleEnd = slotEndTime * scale
        } else {
            let scale = Double(amplitudes.count)
            sampleStart = slotStartFraction * scale
            sampleEnd = slotEndFraction * scale
        }

        return rmsAmplitude(in: amplitudes, from: sampleStart, to: sampleEnd)
    }

    private nonisolated static func rmsAmplitude(
        in amplitudes: [Float],
        from start: Double,
        to end: Double
    ) -> Float {
        guard !amplitudes.isEmpty else { return 0 }
        let count = Double(amplitudes.count)
        let clampedStart = min(max(start, 0), count)
        let clampedEnd = min(max(end, clampedStart), count)
        let span = clampedEnd - clampedStart
        guard span > 1e-9 else {
            return interpolatedAmplitude(in: amplitudes, at: clampedStart)
        }

        let first = min(Int(floor(clampedStart)), amplitudes.count - 1)
        let last = min(max(Int(ceil(clampedEnd)) - 1, first), amplitudes.count - 1)
        if first == last, span < 1 {
            return interpolatedAmplitude(
                in: amplitudes,
                at: (clampedStart + clampedEnd) * 0.5
            )
        }

        var weightedEnergy = 0.0
        var totalWeight = 0.0
        for index in first...last {
            let overlap = min(Double(index + 1), clampedEnd)
                - max(Double(index), clampedStart)
            guard overlap > 0 else { continue }
            let value = Double(amplitudes[index])
            weightedEnergy += overlap * value * value
            totalWeight += overlap
        }
        guard totalWeight > 0 else { return 0 }
        return Float(sqrt(weightedEnergy / totalWeight))
    }

    private nonisolated static func interpolatedAmplitude(
        in amplitudes: [Float],
        at position: Double
    ) -> Float {
        let shifted = position - 0.5
        let lower = min(max(Int(floor(shifted)), 0), amplitudes.count - 1)
        let upper = min(lower + 1, amplitudes.count - 1)
        let fraction = min(max(shifted - Double(lower), 0), 1)
        let blended = Double(amplitudes[lower]) * (1 - fraction)
            + Double(amplitudes[upper]) * fraction
        return Float(blended)
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 15.0,
                paused: Self.shouldPauseTimeline(
                    isPresented: isPresented,
                    isProcessing: isProcessing
                )
            )
        ) { timeline in
            RibbonCanvas(
                amplitudes: amplitudes,
                actualGeneratedDuration: generatedDuration,
                smoothedElapsed: smoothedElapsed,
                smoothedGeneratedDuration: smoothedGeneratedDuration,
                smoothedTotalDuration: smoothedTotalDuration,
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
                    onSeek(
                        Self.seekTime(
                            forLocationX: value.location.x,
                            width: ribbonWidth,
                            generatedDuration: generatedDuration,
                            totalDuration: totalDuration
                        )
                    )
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
        .onChange(of: elapsed) { oldValue, newValue in
            guard isPresented else { return }
            let delta = newValue - oldValue
            let isJump = delta < 0 || delta > 1.0
            if isPlaying, !isJump, delta > 0 {
                let target = min(newValue + delta, generatedDuration)
                withAnimation(.linear(duration: 0.25)) {
                    smoothedElapsed = target
                }
            } else {
                withAnimation(.smooth(duration: isJump ? 0.35 : 0.2)) {
                    smoothedElapsed = newValue
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            guard isPresented, !playing else { return }
            withAnimation(.smooth(duration: 0.2)) {
                smoothedElapsed = elapsed
            }
        }
        .onChange(of: generatedDuration) { oldValue, newValue in
            guard isPresented else { return }
            if newValue < oldValue {
                snapTimelineState()
            } else {
                withAnimation(.smooth(duration: 0.45)) {
                    smoothedGeneratedDuration = newValue
                }
            }
        }
        .onChange(of: totalDuration) { oldValue, newValue in
            guard isPresented else { return }
            if oldValue <= 0 || newValue <= 0 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    smoothedTotalDuration = newValue
                }
            } else {
                withAnimation(.smooth(duration: 0.45)) {
                    smoothedTotalDuration = newValue
                }
            }
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            guard presented else { return }
            snapTimelineState()
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

    private func snapTimelineState() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            smoothedElapsed = elapsed
            smoothedGeneratedDuration = generatedDuration
            smoothedTotalDuration = totalDuration
        }
    }
}

private struct RibbonCanvas: View, Animatable {
    var amplitudes: [Float]
    var actualGeneratedDuration: TimeInterval
    var smoothedElapsed: TimeInterval
    var smoothedGeneratedDuration: TimeInterval
    var smoothedTotalDuration: TimeInterval
    var phase: Double

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(
                smoothedElapsed,
                AnimatablePair(smoothedGeneratedDuration, smoothedTotalDuration)
            )
        }
        set {
            smoothedElapsed = newValue.first
            smoothedGeneratedDuration = newValue.second.first
            smoothedTotalDuration = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let count = VoiceRibbonView.barCount(forWidth: size.width)
            guard count > 0, size.height > 0 else { return }

            let midY = size.height / 2
            let strokeStyle = StrokeStyle(
                lineWidth: VoiceRibbonView.barLineWidth,
                lineCap: .round
            )
            let hasDuration = smoothedTotalDuration > 0
            let revealFraction: Double = if hasDuration {
                min(max(smoothedGeneratedDuration / smoothedTotalDuration, 0), 1)
            } else {
                amplitudes.isEmpty ? 0 : 1
            }
            let playedFraction: Double = if hasDuration {
                min(max(smoothedElapsed / smoothedTotalDuration, 0), revealFraction)
            } else {
                0
            }

            let maximum = max(amplitudes.max() ?? 0, 0.0001)
            let sweep = (phase / 1.6)
                .truncatingRemainder(dividingBy: 1.4) - 0.2

            var pending = Path()
            var shimmerSoft = Path()
            var shimmerBright = Path()
            var live = Path()
            var played = Path()
            var transitioning: [(x: Double, halfHeight: Double, opacity: Double, isPlayed: Bool)] = []

            for slot in 0..<count {
                let x = VoiceRibbonView.barXPosition(
                    slot: slot,
                    count: count,
                    width: size.width
                )
                let slotCenter = (Double(slot) + 0.5) / Double(count)
                let waveformSample = VoiceRibbonView.slotAmplitude(
                    slot: slot,
                    slotCount: count,
                    amplitudes: amplitudes,
                    actualGeneratedDuration: actualGeneratedDuration,
                    displayTotalDuration: smoothedTotalDuration
                )
                let reveal: Double = if waveformSample != nil {
                    VoiceRibbonView.revealFactor(
                        forSlot: slot,
                        slotCount: count,
                        revealFraction: revealFraction
                    )
                } else {
                    0
                }

                if reveal >= 0.999, let sample = waveformSample {
                    let normalized = Double(sample / maximum)
                    let halfHeight = max(1.5, normalized * (size.height * 0.44))
                    if slotCenter <= playedFraction {
                        played.move(to: CGPoint(x: x, y: midY - halfHeight))
                        played.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                    } else {
                        live.move(to: CGPoint(x: x, y: midY - halfHeight))
                        live.addLine(to: CGPoint(x: x, y: midY + halfHeight))
                    }
                } else {
                    let noise = placeholderAmplitude(index: slot, phase: phase)
                    let pendingHalfHeight = max(1.5, noise * (size.height * 0.3))
                    let shine = max(1 - abs(slotCenter - sweep) / 0.14, 0)

                    if reveal <= 0.001 || waveformSample == nil {
                        if shine > 0.66 {
                            shimmerBright.move(to: CGPoint(x: x, y: midY - pendingHalfHeight))
                            shimmerBright.addLine(to: CGPoint(x: x, y: midY + pendingHalfHeight))
                        } else if shine > 0.33 {
                            shimmerSoft.move(to: CGPoint(x: x, y: midY - pendingHalfHeight))
                            shimmerSoft.addLine(to: CGPoint(x: x, y: midY + pendingHalfHeight))
                        } else {
                            pending.move(to: CGPoint(x: x, y: midY - pendingHalfHeight))
                            pending.addLine(to: CGPoint(x: x, y: midY + pendingHalfHeight))
                        }
                    } else if let sample = waveformSample {
                        let normalized = Double(sample / maximum)
                        let liveHalfHeight = max(1.5, normalized * (size.height * 0.44))
                        let halfHeight = pendingHalfHeight
                            + (liveHalfHeight - pendingHalfHeight) * reveal
                        let pendingOpacity = shine > 0.66 ? 0.26 : (shine > 0.33 ? 0.16 : 0.09)
                        let opacity = pendingOpacity + (0.18 - pendingOpacity) * reveal
                        transitioning.append((
                            x: x,
                            halfHeight: halfHeight,
                            opacity: opacity,
                            isPlayed: slotCenter <= playedFraction
                        ))
                    }
                }
            }

            context.stroke(
                pending,
                with: .color(.primary.opacity(0.09)),
                style: strokeStyle
            )
            context.stroke(
                shimmerSoft,
                with: .color(.primary.opacity(0.16)),
                style: strokeStyle
            )
            context.stroke(
                shimmerBright,
                with: .color(.primary.opacity(0.26)),
                style: strokeStyle
            )
            context.stroke(
                live,
                with: .color(.primary.opacity(0.18)),
                style: strokeStyle
            )
            for bar in transitioning {
                var segment = Path()
                segment.move(to: CGPoint(x: bar.x, y: midY - bar.halfHeight))
                segment.addLine(to: CGPoint(x: bar.x, y: midY + bar.halfHeight))
                let color: Color = bar.isPlayed
                    ? .accentColor
                    : .primary.opacity(bar.opacity)
                context.stroke(segment, with: .color(color), style: strokeStyle)
            }
            context.stroke(
                played,
                with: .color(.accentColor),
                style: strokeStyle
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
