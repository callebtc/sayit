import Foundation
import Testing
@testable import PlaybackDSP

@Suite("Pitch-preserving playback DSP")
struct TimeStretchTests {
    static let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

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
        for rate in [0, -1, 3, Double.nan, Double.infinity] {
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
}
