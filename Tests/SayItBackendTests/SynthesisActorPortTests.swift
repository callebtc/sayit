import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Synthesis actor speech-model port")
struct SynthesisActorPortTests {
    @Test("Streamed synthesis runs through the scripted session and clock")
    func streamedSynthesisThroughPort() async throws {
        let session = ScriptedSpeechModelSession()
        let clock = ControllableSynthesisClock()
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
        session.enqueueStreamFailure(.inputTooLong)
        let synthesizer = makeSynthesizer(
            session: session,
            clock: ControllableSynthesisClock()
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
        #expect(session.streamCalls.count == 3)
    }

    @Test("Unretryable input-too-long failures surface the original error")
    func unretryableMarkerSurfacesOriginalError() async throws {
        let session = ScriptedSpeechModelSession()
        session.enqueueStreamFailure(.inputTooLong)
        let synthesizer = makeSynthesizer(
            session: session,
            clock: ControllableSynthesisClock()
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
        } catch let error as ScriptedSpeechModelError {
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
            clock: ControllableSynthesisClock()
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
        let anchorFlags: [Bool?] = [false]
        #expect(
            session.oneShotCalls.map(\.allowTuningSelectedGeneration)
                == anchorFlags
        )

        _ = try await synthesizer.generateVoiceSample(
            model: omniVoice,
            text: "Sample",
            language: omniVoice.defaultLanguage,
            tuning: VoiceSynthesisTuning(preset: "natural", parameters: [:]),
            seed: 7
        )
        let allFlags: [Bool?] = [false, true]
        #expect(
            session.oneShotCalls.map(\.allowTuningSelectedGeneration)
                == allFlags
        )
    }

    @Test("Loader failures surface unchanged and leave no loaded session")
    func loaderFailureSurfaces() async throws {
        let loader = ScriptedSpeechModelLoader(session: nil)
        let synthesizer = SynthesisActor(
            modelURLProvider: { _ in URL(filePath: "/tmp/scripted-model") },
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        let model = try firstModel()
        await #expect(throws: ScriptedSpeechModelError.self) {
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
        #expect(loader.loadCount == 1)
        await synthesizer.unloadModel()
    }

    @Test("Idle unload fires through the clock after an operation finishes")
    func idleUnloadThroughClock() async throws {
        let session = ScriptedSpeechModelSession()
        let clock = ControllableSynthesisClock()
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
        clock: ControllableSynthesisClock
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
