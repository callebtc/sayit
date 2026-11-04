import DramaTTS
import Foundation
import MLX
import MLXAudioCore
import Testing
@testable import SayItBackend

@Suite("DramaTTS integration", .serialized)
struct DramaLibraryTests {
    @Test("Drama prompts preserve paragraph metadata separately")
    func promptText() {
        #expect(DramaLibraryModel.promptText("One.\n\nTwo.") == "One.  Two.")
    }

    @Test("Installed Q4 streams finite speech and recovers after cancellation")
    func installedQ4() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SAYIT_DRAMATTS_MODEL"],
              let referencePath = environment["SAYIT_DRAMATTS_REFERENCE"] else { return }
        func seconds(_ start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let (_, referenceAudio) = try loadAudioArray(
            from: URL(fileURLWithPath: referencePath), sampleRate: 44_100
        )
        let reference = referenceAudio.asArray(Float.self)
        let referenceText = "Hello, this is Drama Three speaking natively on this Mac."
        let started = ContinuousClock.now
        let model = try await DramaLibraryModel.fromDirectory(URL(fileURLWithPath: path))
        print("DRAMATTS_LOAD seconds=\(seconds(started))")
        var parameters = model.defaultGenerationParameters
        parameters.seed = 42
        var first: Double?
        var samples: [Float] = []
        var pieces = 0
        let speechStarted = ContinuousClock.now
        for try await event in model.generateStream(
            text: "A familiar voice can begin reading while the next sentence is prepared.",
            voice: nil, refAudio: MLXArray(reference), refText: referenceText,
            language: nil, generationParameters: parameters) {
            if case .audio(let audio) = event {
                if first == nil { first = seconds(speechStarted) }
                samples += audio.asArray(Float.self)
                pieces += 1
            }
        }
        let elapsed = seconds(speechStarted)
        #expect(pieces > 1)
        #expect(!samples.isEmpty && samples.allSatisfy(\.isFinite))
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        #expect(rms > 0.001)
        print("DRAMATTS_Q4 firstAudio=\(first ?? -1) total=\(elapsed) audio=\(Double(samples.count)/44100) rtf=\(elapsed/(Double(samples.count)/44100)) pieces=\(pieces) rms=\(rms)")
        let task = Task {
            for try await _ in model.generateStream(text: String(repeating: "This is a cancellation test. ", count: 20),
                voice: nil, refAudio: MLXArray(reference), refText: referenceText,
                language: nil, generationParameters: parameters) {
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
        }
        try await Task.sleep(for: .seconds(1))
        let cancelStarted = ContinuousClock.now
        task.cancel()
        do { try await task.value; Issue.record("Cancelled synthesis unexpectedly succeeded") }
        catch is CancellationError { }
        let recovery = try await model.generate(text: "Ready again.", voice: nil, refAudio: MLXArray(reference),
            refText: referenceText, language: nil, generationParameters: parameters)
        #expect(recovery.size > 0)
        print("DRAMATTS_CANCEL_AND_RECOVER seconds=\(seconds(cancelStarted))")
        let anchor = Task {
            let audio = try await model.generate(text: String(repeating: "An automatic voice must cancel promptly. ", count: 20),
                voice: nil, refAudio: nil, refText: nil, language: nil, generationParameters: parameters)
            return audio.size
        }
        try await Task.sleep(for: .seconds(1))
        anchor.cancel()
        do { _ = try await anchor.value; Issue.record("Cancelled anchor unexpectedly succeeded") }
        catch is CancellationError { }
    }
}
