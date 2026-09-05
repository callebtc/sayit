import Foundation
import Testing
@testable import SayItBackend

@Suite("PCM stream conditioning")
struct PCMStreamConditionerTests {
    @Test("Speech timestamps account for the outgoing tail and paragraph silence once")
    func speechStartOffsets() throws {
        var conditioner = try PCMStreamConditioner(sampleRate: 1_000)
        #expect(conditioner.speechStartFrameOffset(
            logicalChunkIndex: 0, startsParagraph: true, paragraphPauseFrameCount: 500
        ) == 0)
        _ = try conditioner.append(
            signal(count: 100, phase: 0), logicalChunkIndex: 0,
            startsParagraph: true, paragraphPauseFrameCount: 0
        )
        #expect(conditioner.retainedFrameCount == 8)
        #expect(conditioner.speechStartFrameOffset(
            logicalChunkIndex: 1, startsParagraph: true, paragraphPauseFrameCount: 500
        ) == 508)
        _ = try conditioner.append(
            signal(count: 100, phase: 100), logicalChunkIndex: 1,
            startsParagraph: true, paragraphPauseFrameCount: 500
        )
        #expect(conditioner.speechStartFrameOffset(
            logicalChunkIndex: 1, startsParagraph: true, paragraphPauseFrameCount: 500
        ) == 0)
        #expect(conditioner.speechStartFrameOffset(
            logicalChunkIndex: 2, startsParagraph: false, paragraphPauseFrameCount: 0
        ) == 0)
        _ = conditioner.finish()
        #expect(conditioner.retainedFrameCount == 0)
    }

    @Test("Streaming fragments from one logical chunk preserve frame count")
    func contiguousFragments() throws {
        var conditioner = try PCMStreamConditioner(sampleRate: 1_000)
        var output = try conditioner.append(
            signal(count: 20, phase: 0),
            logicalChunkIndex: 0,
            startsParagraph: true,
            paragraphPauseFrameCount: 0
        )
        output += try conditioner.append(
            signal(count: 20, phase: 20),
            logicalChunkIndex: 0,
            startsParagraph: true,
            paragraphPauseFrameCount: 0
        )
        output += conditioner.finish()

        #expect(output.count == 40)
        #expect(output.first == 0)
        #expect(output.last == 0)
    }

    @Test("Logical chunk boundaries use one equal-power overlap")
    func logicalBoundary() throws {
        var conditioner = try PCMStreamConditioner(sampleRate: 1_000)
        var output = try conditioner.append(
            signal(count: 20, phase: 0),
            logicalChunkIndex: 0,
            startsParagraph: false,
            paragraphPauseFrameCount: 0
        )
        output += try conditioner.append(
            signal(count: 20, phase: 120),
            logicalChunkIndex: 1,
            startsParagraph: false,
            paragraphPauseFrameCount: 0
        )
        output += conditioner.finish()

        #expect(output.count == 40 - conditioner.boundaryFrameCount)
        #expect(output.allSatisfy { abs($0) <= 0.98 })
    }

    @Test("Paragraph boundaries preserve frames and insert requested silence")
    func paragraphBoundary() throws {
        var conditioner = try PCMStreamConditioner(sampleRate: 1_000)
        var output = try conditioner.append(
            signal(count: 20, phase: 0),
            logicalChunkIndex: 0,
            startsParagraph: false,
            paragraphPauseFrameCount: 0
        )
        output += try conditioner.append(
            signal(count: 20, phase: 20),
            logicalChunkIndex: 1,
            startsParagraph: true,
            paragraphPauseFrameCount: 10
        )
        output += conditioner.finish()

        #expect(output.count == 50)
        #expect(output.contains { $0 == 0 })
    }

    @Test("Invalid samples and sample rates are rejected")
    func invalidInput() throws {
        #expect(throws: (any Error).self) {
            _ = try PCMStreamConditioner(sampleRate: 0)
        }
        var conditioner = try PCMStreamConditioner(sampleRate: 24_000)
        #expect(throws: (any Error).self) {
            _ = try conditioner.append(
                [.nan],
                logicalChunkIndex: 0,
                startsParagraph: false,
                paragraphPauseFrameCount: 0
            )
        }
    }

    @Test("Safety limiting bounds generated and crossfaded samples")
    func safetyLimit() throws {
        var conditioner = try PCMStreamConditioner(sampleRate: 1_000)
        let loud = (0..<40).map { $0.isMultiple(of: 2) ? Float(3) : -3 }
        var output = try conditioner.append(
            loud,
            logicalChunkIndex: 0,
            startsParagraph: false,
            paragraphPauseFrameCount: 0
        )
        output += try conditioner.append(
            loud,
            logicalChunkIndex: 1,
            startsParagraph: false,
            paragraphPauseFrameCount: 0
        )
        output += conditioner.finish()

        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
    }

    @Test("Transition ramps reach silence without changing duration")
    func transitionRamps() {
        let samples = [Float](repeating: 0.5, count: 8)
        let fadedIn = PCMTransitionRamp.fadeIn(samples)
        let fadedOut = PCMTransitionRamp.fadeOut(samples)

        #expect(fadedIn.count == samples.count)
        #expect(fadedOut.count == samples.count)
        #expect(fadedIn.first == 0)
        #expect(fadedIn.last == 0.5)
        #expect(fadedOut.first == 0.5)
        #expect(fadedOut.last == 0)
    }

    @Test("Equal-power crossfade reaches both endpoints")
    func crossfadeEndpoints() {
        let outgoing = ArraySlice([Float](repeating: 0.5, count: 8))
        let incoming = ArraySlice([Float](repeating: -0.5, count: 8))
        let output = PCMTransitionRamp.equalPowerCrossfade(
            outgoing: outgoing,
            incoming: incoming
        )

        #expect(output.first == 0.5)
        #expect(output.last == -0.5)
        #expect(output.count == 8)
    }

    private func signal(count: Int, phase: Int) -> [Float] {
        (0..<count).map { frame in
            Float(sin(Double(frame + phase) * 0.17) * 0.4)
        }
    }
}
