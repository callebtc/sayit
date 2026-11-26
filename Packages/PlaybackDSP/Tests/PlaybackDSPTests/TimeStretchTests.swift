import Foundation
import Testing
@testable import PlaybackDSP

@Suite("Pitch-preserving playback DSP")
struct TimeStretchTests {
    static let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    static func tone(sampleRate: Double, duration: Double = 3) -> [Float] {
        (0..<Int(sampleRate * duration)).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = min(1, time / 0.02, (duration - time) / 0.02)
            return Float(0.25 * envelope * sin(2 * .pi * 220 * time))
        }
    }

    @Test("All speeds preserve pitch, duration and level", arguments: rates, [24_000.0, 44_100.0, 48_000.0])
    func pitchAndDuration(rate: Double, sampleRate: Double) throws {
        let input = Self.tone(sampleRate: sampleRate)
        let stream = try TimeStretchStream(sampleRate: sampleRate, rate: rate)
        var output: [Float] = []
        // Irregular chunks exercise cumulative rounding and continuous state.
        for start in stride(from: 0, to: input.count, by: 997) {
            output += try stream.process(Array(input[start..<min(start + 997, input.count)]))
        }
        output += try stream.process([], final: true)
        #expect(output.count == Int((Double(input.count) / rate).rounded()))
        #expect(output.allSatisfy { $0.isFinite })
        let middle = Array(output[Int(sampleRate / 4)..<(output.count - Int(sampleRate / 4))])
        let rms = sqrt(middle.reduce(0.0) { $0 + Double($1 * $1) } / Double(middle.count))
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) * sampleRate / Double(middle.count)
        #expect(abs(frequency - 220) < 3)
        #expect(rms > 0.10 && rms < 0.25)
        #expect((output.map { abs($0) }.max() ?? 0) < 0.5)
        if rate == 1 { #expect(output == input) }
    }

    @Test("Short clips drain their tail at every speed", arguments: rates)
    func shortTail(rate: Double) throws {
        for count in [1, 37, 240, 2400] {
            let stream = try TimeStretchStream(sampleRate: 24_000, rate: rate)
            let output = try stream.process([Float](repeating: 0.1, count: count), final: true)
            #expect(output.count == Int((Double(count) / rate).rounded()))
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test("Invalid inputs fail and finalized streams cannot be reused")
    func invalidInputs() throws {
        for rate in [0, -1, 0.49, 3.01, Double.nan, Double.infinity] {
            #expect(throws: TimeStretchStream.Failure.self) {
                try TimeStretchStream(sampleRate: 24_000, rate: rate)
            }
        }
        #expect(throws: TimeStretchStream.Failure.self) {
            try TimeStretchStream(sampleRate: 0, rate: 1)
        }
        let stream = try TimeStretchStream(sampleRate: 24_000, rate: 1.5)
        #expect(throws: TimeStretchStream.Failure.self) { try stream.process([.nan]) }
        #expect(try stream.process([], final: true).isEmpty)
        #expect(throws: TimeStretchStream.Failure.self) { try stream.process([0]) }
    }

    @Test("New streams after seek or speed change do not carry old audio")
    func resetIsolation() throws {
        let first = try TimeStretchStream(sampleRate: 24_000, rate: 2)
        _ = try first.process(Self.tone(sampleRate: 24_000))
        let second = try TimeStretchStream(sampleRate: 24_000, rate: 0.5)
        let silence = try second.process([Float](repeating: 0, count: 24_000), final: true)
        #expect(silence.allSatisfy { abs($0) < 0.0001 })
    }

    @Test("Long recordings above 2x drain cleanly without tail failure", arguments: [2.1, 2.75, 3.0])
    func longClipAboveTwoX(rate: Double) throws {
        let sampleRate = 24_000.0
        // Vary pitch across 1-second tiles so Sonic encounters non-divisible
        // pitch periods over a 180-second stream (~4.32M frames).
        let pitches = [127.0, 149.0, 173.0, 197.0, 223.0]
        let tiles: [[Float]] = pitches.map { freq in
            (0..<Int(sampleRate)).map { frame in
                let t = Double(frame) / sampleRate
                return Float(0.2 * sin(2 * .pi * freq * t) + 0.08 * sin(2 * .pi * freq * 2 * t))
            }
        }
        let stream = try TimeStretchStream(sampleRate: sampleRate, rate: rate)
        let totalInputFrames = 180 * Int(sampleRate)
        var outputFrames = 0
        for second in 0..<180 {
            let chunk = tiles[second % tiles.count]
            let stretched = try stream.process(chunk)
            #expect(stretched.allSatisfy { $0.isFinite })
            outputFrames += stretched.count
        }
        let tail = try stream.process([], final: true)
        #expect(tail.allSatisfy { $0.isFinite })
        outputFrames += tail.count

        let expected = Double(totalInputFrames) / rate
        #expect(outputFrames > 0)
        #expect(Double(outputFrames) <= expected.rounded() + 1)
        #expect(Double(outputFrames) >= expected * 0.99)
    }

    @Test("Long slow-rate recordings preserve trailing audio without clipping")
    func longClipSlowRatePreservesTail() throws {
        let sampleRate = 24_000.0
        let rate = 0.5
        let pitches = [127.0, 149.0, 173.0, 197.0, 223.0]
        let tiles: [[Float]] = pitches.map { freq in
            (0..<Int(sampleRate)).map { frame in
                let t = Double(frame) / sampleRate
                return Float(0.2 * sin(2 * .pi * freq * t))
            }
        }
        let stream = try TimeStretchStream(sampleRate: sampleRate, rate: rate)
        let totalSeconds = 180
        for second in 0..<(totalSeconds - 2) {
            let chunk = try stream.process(tiles[second % tiles.count])
            #expect(chunk.allSatisfy { $0.isFinite })
        }
        // Append 1.75 s of silence followed by a loud 0.25 s 1 kHz beacon at the very end.
        var trailingWindow: [Float] = []
        trailingWindow += try stream.process([Float](repeating: 0, count: Int(sampleRate)))
        var finalSecond = [Float](repeating: 0, count: Int(sampleRate))
        let beaconStart = Int(sampleRate * 0.75)
        for index in beaconStart..<Int(sampleRate) {
            let t = Double(index) / sampleRate
            finalSecond[index] = Float(0.9 * sin(2 * .pi * 1000 * t))
        }
        trailingWindow += try stream.process(finalSecond)
        trailingWindow += try stream.process([], final: true)

        let loudTailSamples = trailingWindow.filter { abs($0) > 0.3 }.count
        let maxTailAmplitude = trailingWindow.suffix(Int(sampleRate * 0.5)).map { abs($0) }.max() ?? 0
        #expect(trailingWindow.allSatisfy { $0.isFinite })
        #expect(loudTailSamples > Int(sampleRate * 0.25))
        #expect(maxTailAmplitude > 0.5)
    }
}
