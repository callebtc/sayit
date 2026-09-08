import CPlaybackDSP
import Foundation

/// Stateful mono Float32 stretching. Keep one instance for a continuous source;
/// create a new instance after seeking or changing speed. Call only serially.
public final class TimeStretchStream {
    public static let engineName = "Rubber Band R3"
    private let handle: UnsafeMutableRawPointer
    private var isFinished = false

    public enum Failure: Error {
        case invalidConfiguration
        case invalidSamples
        case processingFailed
        case alreadyFinished
    }

    public init(sampleRate: Double, rate: Double) throws {
        guard let handle = sayit_stretch_create(sampleRate, rate) else {
            throw Failure.invalidConfiguration
        }
        self.handle = handle
    }

    deinit { sayit_stretch_destroy(handle) }

    /// Finalization drains lookahead and trims padding to round(inputFrames / rate).
    /// At 1×, samples pass through unchanged.
    public func process(_ samples: [Float], final: Bool = false) throws -> [Float] {
        guard !isFinished else { throw Failure.alreadyFinished }
        guard samples.count <= Int(Int32.max), samples.allSatisfy(\.isFinite) else {
            throw Failure.invalidSamples
        }
        var count: Int32 = 0
        let result = samples.withUnsafeBufferPointer {
            sayit_stretch_process(handle, $0.baseAddress, Int32($0.count), final ? 1 : 0, &count)
        }
        guard count >= 0 else { throw Failure.processingFailed }
        isFinished = final
        guard count > 0, let result else { return [] }
        let output = Array(UnsafeBufferPointer(start: result, count: Int(count)))
        guard output.allSatisfy(\.isFinite) else { throw Failure.processingFailed }
        return output
    }
}
