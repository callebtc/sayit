@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SayItCore

@Suite("Voice recording validation")
struct VoiceRecordingProcessorTests {
    @Test("Processing trims silence, mixes to mono, and resamples")
    func processingPipeline() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "source.wav")
        let destination = root.appending(path: "reference.wav")
        try writeFixture(
            to: source,
            sampleRate: 48_000,
            signalDuration: 4,
            amplitude: 0.2
        )

        let analysis = try VoiceRecordingProcessor().process(
            source: source,
            destination: destination,
            targetSampleRate: 24_000,
            minimumDuration: 3,
            maximumDuration: 10
        )

        #expect((3.9...4.3).contains(analysis.duration))
        #expect(analysis.sampleRate == 24_000)
        let output = try AVAudioFile(forReading: destination)
        #expect(output.processingFormat.channelCount == 1)
        #expect(output.processingFormat.sampleRate == 24_000)
    }

    @Test("Silent, clipped, short, and long recordings are rejected")
    func rejectionReasons() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let destination = root.appending(path: "reference.wav")

        for fixture in [
            ("silent.wav", 4.0, Float(0)),
            ("clipped.wav", 4.0, Float(1)),
            ("short.wav", 1.0, Float(0.2)),
            ("long.wav", 12.0, Float(0.2))
        ] {
            let source = root.appending(path: fixture.0)
            try writeFixture(
                to: source,
                sampleRate: 24_000,
                signalDuration: fixture.1,
                amplitude: fixture.2
            )
            #expect(throws: VoiceRecordingError.self) {
                _ = try VoiceRecordingProcessor().process(
                    source: source,
                    destination: destination,
                    targetSampleRate: 24_000,
                    minimumDuration: 3,
                    maximumDuration: 10
                )
            }
        }
    }

    @Test("Bluetooth microphone audio is accepted and normalized")
    func bluetoothMicrophoneAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "airpods-style.wav")
        let destination = root.appending(path: "reference.wav")
        try writeFixture(
            to: source,
            sampleRate: 16_000,
            signalDuration: 4,
            amplitude: 0.2,
            channelCount: 1
        )

        let analysis = try VoiceRecordingProcessor().process(
            source: source,
            destination: destination,
            targetSampleRate: 24_000,
            minimumDuration: 3,
            maximumDuration: 10
        )

        #expect((3.9...4.3).contains(analysis.duration))
        #expect(analysis.sampleRate == 24_000)
        let output = try AVAudioFile(forReading: destination)
        #expect(output.processingFormat.channelCount == 1)
        #expect(output.processingFormat.sampleRate == 24_000)
    }

    @Test("Quiet recordings are level-normalized exactly once")
    func quietRecordingNormalizationIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "quiet.wav")
        let firstReference = root.appending(path: "reference.wav")
        let secondReference = root.appending(path: "reference-copy.wav")
        try writeFixture(
            to: source,
            sampleRate: 48_000,
            signalDuration: 4,
            amplitude: 0.01
        )

        let processor = VoiceRecordingProcessor()
        let first = try processor.process(
            source: source,
            destination: firstReference,
            targetSampleRate: 24_000,
            minimumDuration: 3,
            maximumDuration: 10
        )
        let second = try processor.validateProcessedReference(
            source: firstReference,
            destination: secondReference,
            targetSampleRate: 24_000,
            minimumDuration: 3,
            maximumDuration: 10
        )

        #expect((0.039...0.041).contains(first.rootMeanSquare))
        #expect((0.039...0.041).contains(second.rootMeanSquare))
        #expect(first.peak <= 0.95)
        #expect(
            try Data(contentsOf: secondReference)
                == Data(contentsOf: firstReference)
        )
    }

    @Test("Fish Audio reference formats use the native 44.1 kHz rate")
    func fishAudioReferenceSampleRate() {
        #expect(
            VoiceReferenceFormat.sampleRate(
                forModelType: "fish_qwen3_omni"
            ) == 44_100
        )
        #expect(
            VoiceReferenceFormat.sampleRate(forModelType: "fish_speech")
                == 44_100
        )
        #expect(
            VoiceReferenceFormat.sampleRate(forModelType: "qwen3_tts")
                == 24_000
        )
    }

    @Test("Backend validation rejects references that skipped processing")
    func unprocessedReferenceIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "unprocessed.wav")
        try writeFixture(
            to: source,
            sampleRate: 24_000,
            signalDuration: 4,
            amplitude: 0.2,
            channelCount: 1
        )

        #expect(throws: VoiceRecordingError.notProcessed) {
            _ = try VoiceRecordingProcessor().validateProcessedReference(
                source: source,
                destination: root.appending(path: "reference.wav"),
                targetSampleRate: 24_000,
                minimumDuration: 3,
                maximumDuration: 10
            )
        }
    }

    @Test("Out-of-range processing parameters are rejected")
    func outOfRangeParameters() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SayItRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "source.wav")
        try writeFixture(
            to: source,
            sampleRate: 24_000,
            signalDuration: 4,
            amplitude: 0.2
        )

        #expect(throws: VoiceRecordingError.outOfRange) {
            _ = try VoiceRecordingProcessor().process(
                source: source,
                destination: root.appending(path: "reference.wav"),
                targetSampleRate: 1_000,
                minimumDuration: 3,
                maximumDuration: 10
            )
        }
    }

    private func writeFixture(
        to url: URL,
        sampleRate: Double,
        signalDuration: TimeInterval,
        amplitude: Float,
        channelCount: AVAudioChannelCount = 2
    ) throws {
        let silenceFrames = Int(sampleRate * 0.25)
        let signalFrames = Int(sampleRate * signalDuration)
        let samples = [Float](repeating: 0, count: silenceFrames)
            + (0..<signalFrames).map {
                amplitude * sin(
                    2 * .pi * 220 * Float($0) / Float(sampleRate)
                )
            }
            + [Float](repeating: 0, count: silenceFrames)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channelIndex in 0..<Int(channelCount) {
            let channel = try #require(
                buffer.floatChannelData?[channelIndex]
            )
            samples.withUnsafeBufferPointer {
                channel.update(from: $0.baseAddress!, count: samples.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
    }
}
