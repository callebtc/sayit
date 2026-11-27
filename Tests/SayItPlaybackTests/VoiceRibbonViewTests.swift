import Foundation
import Testing
@testable import SayIt
@testable import SayItBackend

@Suite("Voice ribbon waveform stability")
struct VoiceRibbonViewTests {
    @Test("Backend amplitude bucketing never drops bucket count when crossing capacity")
    func backendBucketsStayMonotonic() {
        let count = SayItBackend.PlaybackController.displayAmplitudeBucketCount
        let atCapacity = Array(repeating: Float(0.5), count: count)
        let justAboveCapacity = Array(repeating: Float(0.5), count: count + 1)
        let doubleCapacity = Array(repeating: Float(0.5), count: count * 2 + 7)

        let bucketsAtCapacity = SayItBackend.PlaybackController.displayAmplitudeBuckets(
            from: atCapacity,
            count: count
        )
        let bucketsJustAbove = SayItBackend.PlaybackController.displayAmplitudeBuckets(
            from: justAboveCapacity,
            count: count
        )
        let bucketsDouble = SayItBackend.PlaybackController.displayAmplitudeBuckets(
            from: doubleCapacity,
            count: count
        )

        #expect(bucketsAtCapacity.count == count)
        #expect(bucketsJustAbove.count == count)
        #expect(bucketsDouble.count == count)
        #expect(bucketsJustAbove.allSatisfy { abs($0 - 0.5) < 0.0001 })
        #expect(bucketsDouble.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("Backend amplitude bucketing preserves short inputs and energy distribution")
    func backendBucketsPreserveEnergy() {
        let short: [Float] = [0.1, 0.4, 0.9]
        #expect(
            SayItBackend.PlaybackController.displayAmplitudeBuckets(from: short, count: 10) == short
        )
        #expect(
            SayItBackend.PlaybackController.displayAmplitudeBuckets(from: [], count: 10).isEmpty
        )

        // First half loud (0.8), second half quiet (0.2), odd length across boundary.
        let windows = Array(repeating: Float(0.8), count: 100)
            + Array(repeating: Float(0.2), count: 100)
        let buckets = SayItBackend.PlaybackController.displayAmplitudeBuckets(from: windows, count: 4)
        #expect(buckets.count == 4)
        #expect(abs(buckets[0] - 0.8) < 0.0001)
        #expect(abs(buckets[1] - 0.8) < 0.0001)
        #expect(abs(buckets[2] - 0.2) < 0.0001)
        #expect(abs(buckets[3] - 0.2) < 0.0001)
    }

    @Test("Bar x-positions stay on a fixed grid independent of generated chunks")
    func fixedHorizontalGrid() {
        let width = 328.0
        let count = VoiceRibbonView.barCount(forWidth: width)
        #expect(count == VoiceRibbonView.slotCount)

        let positions = (0..<count).map {
            VoiceRibbonView.barXPosition(slot: $0, count: count, width: width)
        }
        #expect(abs(positions[0] - VoiceRibbonView.barLineWidth / 2) < 0.0001)
        #expect(abs(positions[count - 1] - (width - VoiceRibbonView.barLineWidth / 2)) < 0.0001)

        // Uniform spacing across the entire ribbon.
        let expectedStep = (width - VoiceRibbonView.barLineWidth) / Double(count - 1)
        for index in 1..<count {
            #expect(abs((positions[index] - positions[index - 1]) - expectedStep) < 0.0001)
        }
    }

    @Test("Existing waveform slots stay temporally anchored as new chunks arrive")
    func existingSlotsStayAnchoredAsChunksLoad() {
        // 30s total audio with a distinct pulse at 3.0s..4.0s and silence elsewhere.
        let totalDuration = 30.0
        let windowsPerSecond = 20
        let fullWindows: [Float] = (0..<(Int(totalDuration) * windowsPerSecond)).map { index in
            let time = Double(index) / Double(windowsPerSecond)
            return (time >= 3.0 && time < 4.0) ? 0.9 : 0.1
        }

        let slotCount = VoiceRibbonView.slotCount
        // Slot 10 covers [3.125s, 3.4375s), squarely inside the 3.0s..4.0s pulse.
        // Slot 2 covers [0.625s, 0.9375s), squarely inside the 0.1 quiet region.
        let pulseSlot = 10
        let quietSlot = 2

        for generatedDuration in [5.0, 10.0, 18.0, 24.0, 30.0] {
            let prefixCount = Int(generatedDuration * Double(windowsPerSecond))
            let amplitudes = SayItBackend.PlaybackController.displayAmplitudeBuckets(
                from: Array(fullWindows.prefix(prefixCount)),
                count: SayItBackend.PlaybackController.displayAmplitudeBucketCount
            )
            let pulseValue = VoiceRibbonView.slotAmplitude(
                slot: pulseSlot,
                slotCount: slotCount,
                amplitudes: amplitudes,
                actualGeneratedDuration: generatedDuration,
                displayTotalDuration: totalDuration
            )
            let quietValue = VoiceRibbonView.slotAmplitude(
                slot: quietSlot,
                slotCount: slotCount,
                amplitudes: amplitudes,
                actualGeneratedDuration: generatedDuration,
                displayTotalDuration: totalDuration
            )
            #expect(pulseValue != nil)
            #expect(quietValue != nil)
            #expect(abs((pulseValue ?? 0) - 0.9) < 0.02)
            #expect(abs((quietValue ?? 0) - 0.1) < 0.02)

            // Slots beyond actualGeneratedDuration return nil so pending bars stay pending.
            if generatedDuration < totalDuration {
                let pendingSlot = Int((generatedDuration / totalDuration) * Double(slotCount)) + 1
                if pendingSlot < slotCount {
                    #expect(
                        VoiceRibbonView.slotAmplitude(
                            slot: pendingSlot,
                            slotCount: slotCount,
                            amplitudes: amplitudes,
                            actualGeneratedDuration: generatedDuration,
                            displayTotalDuration: totalDuration
                        ) == nil
                    )
                }
            }
        }
    }

    @Test("Reveal factor transitions smoothly from zero to one without endpoint jumps")
    func revealFactorIsMonotonicAndContinuous() {
        let count = VoiceRibbonView.slotCount
        for slot in 0..<count {
            #expect(
                VoiceRibbonView.revealFactor(
                    forSlot: slot,
                    slotCount: count,
                    revealFraction: 0
                ) == 0
            )
            #expect(
                VoiceRibbonView.revealFactor(
                    forSlot: slot,
                    slotCount: count,
                    revealFraction: 1
                ) == 1
            )
        }

        // For a given slot, reveal increases monotonically as revealFraction advances.
        var previous = 0.0
        for step in 0...100 {
            let fraction = Double(step) / 100.0
            let value = VoiceRibbonView.revealFactor(
                forSlot: 48,
                slotCount: count,
                revealFraction: fraction
            )
            #expect(value >= previous - 1e-12)
            previous = value
        }
        #expect(previous == 1.0)
    }

    @Test("Seek maps bar positions to exact timestamps and clamps to generated duration")
    func seekMatchesFixedGrid() {
        let width = 328.0
        let count = VoiceRibbonView.barCount(forWidth: width)

        // Clicking the bar at 25% of a 30s timeline (7.5s) while 15s is generated seeks to 7.5s.
        let quarterX = VoiceRibbonView.barXPosition(slot: count / 4, count: count, width: width)
        let quarterSeek = VoiceRibbonView.seekTime(
            forLocationX: quarterX,
            width: width,
            generatedDuration: 15,
            totalDuration: 30
        )
        let expectedQuarter = (Double(count / 4) / Double(count - 1)) * 30
        #expect(abs(quarterSeek - expectedQuarter) < 0.001)

        // Clicking in the ungenerated region clamps to generatedDuration.
        let farRightX = VoiceRibbonView.barXPosition(slot: count - 1, count: count, width: width)
        let clampedSeek = VoiceRibbonView.seekTime(
            forLocationX: farRightX,
            width: width,
            generatedDuration: 15,
            totalDuration: 30
        )
        #expect(clampedSeek == 15)
    }
}
