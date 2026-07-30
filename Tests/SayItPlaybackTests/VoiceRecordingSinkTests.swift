@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SayIt

@Suite("Voice recording sink")
struct VoiceRecordingSinkTests {
    @Test("The audio tap callback is safe off the main actor")
    @MainActor
    func tapCallbackIsNonisolated() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VoiceRecordingSink(destination: url)
        let callback = VoiceRecorder.tapHandler(for: sink)
        let buffer = try Self.buffer(sampleRate: 16_000)
        let sendableBuffer = SendableAudioBuffer(buffer)

        await Task.detached {
            callback(sendableBuffer.value, AVAudioTime(hostTime: 0))
        }.value
        let reading = sink.finish()

        #expect(reading.errorMessage == nil)
        #expect(reading.frameCount == AVAudioFramePosition(buffer.frameLength))
        #expect(reading.duration > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A Bluetooth-style format change fails gracefully")
    func formatChangeIsReported() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VoiceRecordingSink(destination: url)

        sink.consume(try Self.buffer(sampleRate: 16_000))
        sink.consume(try Self.buffer(sampleRate: 24_000))
        let reading = sink.finish()

        #expect(reading.frameCount > 0)
        #expect(reading.errorMessage?.contains("changed audio format") == true)
    }

    private static func buffer(
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let frameCount: AVAudioFrameCount = 1_024
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            channel[index] = 0.2 * sin(
                2 * .pi * 220 * Float(index) / Float(sampleRate)
            )
        }
        return buffer
    }
}

private struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}
