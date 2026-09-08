@preconcurrency import AVFoundation
import Foundation
import PlaybackDSP

// Offline listening fixtures use exactly the same streaming wrapper as playback.
// Usage: swift run -c release --package-path Packages/PlaybackDSP PlaybackDSPRender input.wav output-directory
@main
struct RenderComparison {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: PlaybackDSPRender input-audio output-directory")
            return
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = input.processingFormat.sampleRate
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TimeStretchStream.Failure.invalidConfiguration
        }
        print("engine,rate,input_frames,output_frames,processing_seconds")
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let url = destination.appendingPathComponent("speed-\(rate).wav")
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            let stream = try TimeStretchStream(sampleRate: sampleRate, rate: rate)
            var outputFrames = 0
            var processingSeconds = 0.0
            input.framePosition = 0
            func write(_ samples: [Float], final: Bool = false) throws {
                let start = ContinuousClock.now
                let stretched = try stream.process(samples, final: final)
                let elapsed = start.duration(to: .now).components
                processingSeconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                guard !stretched.isEmpty else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stretched.count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw TimeStretchStream.Failure.processingFailed
                }
                buffer.frameLength = AVAudioFrameCount(stretched.count)
                for index in stretched.indices { channel[index] = stretched[index] }
                try output.write(from: buffer)
                outputFrames += stretched.count
            }
            while input.framePosition < input.length {
                try input.read(into: inputBuffer)
                guard let channels = inputBuffer.floatChannelData, inputBuffer.frameLength > 0 else {
                    throw TimeStretchStream.Failure.invalidSamples
                }
                let channelCount = Int(input.processingFormat.channelCount)
                var mono = [Float](repeating: 0, count: Int(inputBuffer.frameLength))
                for channel in 0..<channelCount {
                    for frame in mono.indices { mono[frame] += channels[channel][frame] / Float(channelCount) }
                }
                try write(mono)
            }
            try write([], final: true)
            print("\(TimeStretchStream.engineName),\(rate),\(input.length),\(outputFrames),\(processingSeconds)")
        }
    }
}
