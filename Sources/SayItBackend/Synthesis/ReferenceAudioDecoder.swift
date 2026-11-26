@preconcurrency import AVFoundation
import Foundation

/// Decodes a reference audio file to plain mono samples at a target rate.
enum ReferenceAudioDecoder {
    static func decodeMonoSamples(
        from url: URL,
        targetSampleRate: Double
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: frameCount
              ) else {
            throw SynthesisError.invalidReferenceAudio
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw SynthesisError.invalidReferenceAudio
        }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channelIndex in 0..<channelCount {
            for sampleIndex in 0..<count {
                mono[sampleIndex] += channels[channelIndex][sampleIndex]
                    / Float(channelCount)
            }
        }
        let sourceRate = buffer.format.sampleRate
        if abs(sourceRate - targetSampleRate) < 1 {
            return mono
        }
        let outputCount = max(
            Int(Double(mono.count) * targetSampleRate / sourceRate),
            1
        )
        var resampled = [Float](repeating: 0, count: outputCount)
        for outputIndex in 0..<outputCount {
            let sourcePosition = Double(outputIndex) * sourceRate
                / targetSampleRate
            let lower = min(Int(sourcePosition), mono.count - 1)
            let upper = min(lower + 1, mono.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            resampled[outputIndex] =
                mono[lower] * (1 - fraction) + mono[upper] * fraction
        }
        return resampled
    }
}
