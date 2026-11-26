import Foundation
import SayItCore
import Synchronization
import Testing
@testable import SayItBackend

@Suite("Synthesis actor speech-model port")
struct SynthesisActorPortTests {
    @Test("Streamed synthesis runs through the scripted session and clock")
    func streamedSynthesisThroughPort() async throws {
        let session = ScriptedSpeechModelSession()
        let clock = ManualSynthesisClock()
        let synthesizer = makeSynthesizer(session: session, clock: clock)
        await synthesizer.updateConfiguration(
            chunkTarget: 20,
            chunkDelay: 0.25,
            paragraphPause: 0,
            idleUnloadDelay: 0
        )
        let model = try firstModel()
        let stream = await synthesizer.synthesize(
            makeRequest(
                model: model,
                text: "Alpha bravo charlie. Delta echo foxtrot."
            )
        )
        var sawAudio = false
        var metricsCount = 0
        var sawCompleted = false
        for try await event in stream {
            switch event {
            case .audio(_):
                sawAudio = true
            case .metrics(_):
                metricsCount += 1
            case .completed:
                sawCompleted = true
            default:
                break
            }
        }
        await synthesizer.cancelCurrentRequest()
        #expect(sawAudio)
        #expect(metricsCount == 2)
        #expect(sawCompleted)
        #expect(clock.recordedSleeps == [.seconds(0.25)])
        #expect(session.quiesceCount == 1)
        #expect(session.shutdownCount == 0)
    }

    @Test("Input-too-long marker retries with subchunks")
    func inputTooLongMarkerRetries() async throws {
        let session = ScriptedSpeechModelSession()
        session.failNextStreamsWithMarker(count: 1)
        let synthesizer = makeSynthesizer(
            session: session,
            clock: ManualSynthesisClock()
        )
        await synthesizer.updateConfiguration(
            chunkTarget: 650,
            chunkDelay: 0,
            paragraphPause: 0.18,
            idleUnloadDelay: 0
        )
        let model = try firstModel()
        let stream = await synthesizer.synthesize(
            makeRequest(
                model: model,
                text: "Alpha bravo charlie delta echo. "
                    + "Foxtrot golf hotel india juliett."
            )
        )
        var metricsCount = 0
        var sawCompleted = false
        for try await event in stream {
            switch event {
            case .metrics(_):
                metricsCount += 1
            case .completed:
                sawCompleted = true
            default:
                break
            }
        }
        #expect(sawCompleted)
        #expect(metricsCount == 2)
        #expect(session.streamCallCount == 3)
    }

    @Test("Unretryable input-too-long failures surface the original error")
    func unretryableMarkerSurfacesOriginalError() async throws {
        let session = ScriptedSpeechModelSession()
        session.failAllStreamsWithMarker()
        let synthesizer = makeSynthesizer(
            session: session,
            clock: ManualSynthesisClock()
        )
        await synthesizer.updateConfiguration(
            chunkTarget: 650,
            chunkDelay: 0,
            paragraphPause: 0.18,
            idleUnloadDelay: 0
        )
        let model = try firstModel()
        let stream = await synthesizer.synthesize(
            makeRequest(model: model, text: "Hi.")
        )
        do {
            for try await _ in stream {}
            Issue.record("Expected synthesis to fail")
        } catch let error as ScriptedPortError {
            #expect(error == .inputTooLong)
        } catch {
            Issue.record("Expected the original error, got: \(error)")
        }
    }

    @Test("Anchor uses standard generation, voice samples allow tuning-selected generation")
    func anchorAndVoiceSampleDispatch() async throws {
        let session = ScriptedSpeechModelSession()
        let synthesizer = makeSynthesizer(
            session: session,
            clock: ManualSynthesisClock()
        )
        await synthesizer.updateConfiguration(
            chunkTarget: 650,
            chunkDelay: 0,
            paragraphPause: 0.18,
            idleUnloadDelay: 0
        )
        let omniVoice = try omniVoiceModel()
        let stream = await synthesizer.synthesize(
            makeRequest(
                model: omniVoice,
                text: "Alpha bravo charlie.",
                voiceMode: .automaticStable
            )
        )
        for try await _ in stream {}
        await synthesizer.cancelCurrentRequest()
        #expect(session.oneShotAllowFlags == [false])

        _ = try await synthesizer.generateVoiceSample(
            model: omniVoice,
            text: "Sample",
            language: omniVoice.defaultLanguage,
            tuning: VoiceSynthesisTuning(preset: "natural", parameters: [:]),
            seed: 7
        )
        #expect(session.oneShotAllowFlags == [false, true])
    }

    @Test("Loader failures surface unchanged and leave no loaded session")
    func loaderFailureSurfaces() async throws {
        let loader = ScriptedSpeechModelLoader(session: nil)
        let synthesizer = SynthesisActor(
            modelURLProvider: { _ in URL(filePath: "/tmp/scripted-model") },
            loader: loader,
            clock: ManualSynthesisClock()
        )
        let model = try firstModel()
        await #expect(throws: ScriptedPortError.self) {
            _ = try await synthesizer.generateVoiceSample(
                model: model,
                text: "Sample",
                language: model.defaultLanguage,
                tuning: VoiceSynthesisTuning(
                    preset: "natural",
                    parameters: [:]
                ),
                seed: 1
            )
        }
        #expect(await loader.loadCount == 1)
        await synthesizer.unloadModel()
    }

    @Test("Idle unload fires through the clock after an operation finishes")
    func idleUnloadThroughClock() async throws {
        let session = ScriptedSpeechModelSession()
        let clock = ManualSynthesisClock()
        let synthesizer = makeSynthesizer(session: session, clock: clock)
        await synthesizer.updateConfiguration(
            chunkTarget: 650,
            chunkDelay: 0,
            paragraphPause: 0.18,
            idleUnloadDelay: 5
        )
        let model = try firstModel()
        let stream = await synthesizer.synthesize(
            makeRequest(model: model, text: "Alpha bravo charlie.")
        )
        for try await _ in stream {}
        for _ in 0..<1_000 where session.shutdownCount == 0 {
            await Task.yield()
        }
        #expect(session.shutdownCount == 1)
        #expect(clock.recordedSleeps == [.seconds(5)])
    }

    private func makeSynthesizer(
        session: ScriptedSpeechModelSession,
        clock: ManualSynthesisClock
    ) -> SynthesisActor {
        SynthesisActor(
            modelURLProvider: { _ in URL(filePath: "/tmp/scripted-model") },
            loader: ScriptedSpeechModelLoader(session: session),
            clock: clock
        )
    }

    private func makeRequest(
        model: ModelDescriptor,
        text: String,
        voiceMode: VoiceSynthesisMode = .standard
    ) -> SpeechRequest {
        SpeechRequest(
            cleanedText: CleanedText(
                text: text,
                title: "Port test",
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: model.defaultVoice,
            language: model.defaultLanguage,
            voiceMode: voiceMode,
            source: .frontend
        )
    }

    private func firstModel() throws -> ModelDescriptor {
        try #require(ModelCatalogLoader().bundledCatalog().models.first)
    }

    private func omniVoiceModel() throws -> ModelDescriptor {
        try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
                $0.modelType.lowercased() == "omnivoice"
            }
        )
    }
}

private enum ScriptedPortError: Error {
    case inputTooLong
    case loadFailed
}

private actor ScriptedSpeechModelLoader: SpeechModelLoading {
    private let session: ScriptedSpeechModelSession?
    private(set) var loadCount = 0

    init(session: ScriptedSpeechModelSession?) {
        self.session = session
    }

    func load(
        model: ModelDescriptor,
        directory: URL
    ) async throws -> any SpeechModelSession {
        loadCount += 1
        guard let session else {
            throw ScriptedPortError.loadFailed
        }
        return session
    }

    func prepareDependencies(for model: ModelDescriptor) async throws {}
}

private final class ScriptedSpeechModelSession: SpeechModelSession,
    @unchecked Sendable {
    let sampleRate = 24_000.0

    private struct State {
        var oneShotAllowFlags: [Bool] = []
        var streamCallCount = 0
        var quiesceCount = 0
        var shutdownCount = 0
        var markerFailuresRemaining = 0
        var alwaysFailsWithMarker = false
    }

    private let state = Mutex(State())

    var oneShotAllowFlags: [Bool] {
        state.withLock { $0.oneShotAllowFlags }
    }

    var streamCallCount: Int {
        state.withLock { $0.streamCallCount }
    }

    var quiesceCount: Int {
        state.withLock { $0.quiesceCount }
    }

    var shutdownCount: Int {
        state.withLock { $0.shutdownCount }
    }

    func failNextStreamsWithMarker(count: Int) {
        state.withLock { $0.markerFailuresRemaining = count }
    }

    func failAllStreamsWithMarker() {
        state.withLock { $0.alwaysFailsWithMarker = true }
    }

    func generateSamples(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        allowTuningSelectedGeneration: Bool
    ) async throws -> [Float] {
        state.withLock {
            $0.oneShotAllowFlags.append(allowTuningSelectedGeneration)
        }
        return [Float](repeating: 0.1, count: 4_800)
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) -> AsyncThrowingStream<[Float], Error> {
        let shouldFail = state.withLock { state -> Bool in
            state.streamCallCount += 1
            if state.alwaysFailsWithMarker {
                return true
            }
            if state.markerFailuresRemaining > 0 {
                state.markerFailuresRemaining -= 1
                return true
            }
            return false
        }
        if shouldFail {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: SpeechModelInputTooLongError(
                        underlyingError: ScriptedPortError.inputTooLong
                    )
                )
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield([Float](repeating: 0.1, count: 4_800))
            continuation.finish()
        }
    }

    func fittingPieces(
        for chunk: SpeechChunk,
        language: String?,
        voice: String?,
        chunker: TextChunker
    ) async throws -> [SpeechChunk] {
        [chunk]
    }

    func applySpeakingPace(_ pace: SpeakingPace) throws {}

    func quiesce() {
        state.withLock { $0.quiesceCount += 1 }
    }

    func shutdown() {
        state.withLock { $0.shutdownCount += 1 }
    }
}

private final class ManualSynthesisClock: SynthesisClock,
    @unchecked Sendable {
    private struct State {
        var instant: ContinuousClock.Instant
        var sleeps: [Duration] = []
    }

    private let state = Mutex(State(instant: ContinuousClock.now))

    var now: ContinuousClock.Instant {
        state.withLock { $0.instant }
    }

    var recordedSleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.instant = state.instant.advanced(by: duration)
            state.sleeps.append(duration)
        }
        await Task.yield()
    }
}
