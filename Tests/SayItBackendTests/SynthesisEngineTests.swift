import Foundation
import SayItCore
import Testing
@testable import SayItBackend

/// Through-interface coverage of the synthesis engine: requests go in
/// through `BackendSpeechSynthesizing`, and assertions read only the
/// streamed events, the scripted session's recorded calls, the loader's
/// recorded loads, and the clock's recorded sleeps.
@Suite("Synthesis engine", .serialized)
struct SynthesisEngineTests {
    @Test("Model loads once per model and reloads on model change")
    func loadOnceAndReloadOnModelChange() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let first = try catalogModel(id: "kokoro-bf16")
        let second = try catalogModel(id: "kitten-mini-08")

        let firstRun = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: first, text: "Alpha bravo charlie.")
            )
        )
        let secondRun = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: first, text: "Alpha bravo charlie.")
            )
        )
        let thirdRun = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: second, text: "Alpha bravo charlie.")
            )
        )

        #expect(firstRun.error == nil)
        #expect(secondRun.error == nil)
        #expect(thirdRun.error == nil)
        #expect(kinds(firstRun.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "audio(0)", "audio(0)", "metrics(0)",
            "completed",
        ])
        #expect(kinds(secondRun.events) == [
            "chunkStarted(0)", "audio(0)", "audio(0)", "metrics(0)",
            "completed",
        ])
        #expect(kinds(thirdRun.events) == [
            "loadingModel(kitten-mini-08)",
            "modelLoaded(kitten-mini-08)",
            "chunkStarted(0)", "audio(0)", "audio(0)", "metrics(0)",
            "completed",
        ])
        #expect(loader.loadedModelIDs == [first.id, second.id])
        #expect(
            loader.loadedDirectories
                == [
                    URL(filePath: "/tmp/scripted-model"),
                    URL(filePath: "/tmp/scripted-model"),
                ]
        )
        #expect(session.shutdownCount == 1)
        #expect(session.streamCalls.count == 3)
    }

    @Test("Multi-chunk streaming emits ordered events and metrics")
    func multiChunkStreamingEventsAndMetrics() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueStreamBatches([samples(400), samples(400)])
        session.enqueueStreamBatches([samples(400), samples(400)])
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer, chunkTarget: 20)
        let model = try catalogModel(id: "kokoro-bf16")
        let request = makeRequest(
            model: model,
            text: "Alpha bravo charlie. Delta echo foxtrot."
        )

        let outcome = await collectAll(
            await synthesizer.synthesize(request)
        )

        #expect(outcome.error == nil)
        #expect(kinds(outcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "audio(0)", "audio(0)", "metrics(0)",
            "chunkStarted(1)", "audio(1)", "audio(1)", "audio(1)",
            "metrics(1)", "completed",
        ])
        let audio = audioChunks(outcome.events)
        #expect(audio.allSatisfy { $0.requestID == request.id })
        #expect(audio.allSatisfy { $0.sampleRate == 8_000 })
        #expect(audio.allSatisfy { !$0.samples.isEmpty })
        #expect(
            audio.allSatisfy { $0.samples.allSatisfy(\.isFinite) }
        )
        #expect(audio.filter { $0.index == 0 }
            .allSatisfy(\.startsParagraph))
        #expect(audio.filter { $0.index == 1 }
            .allSatisfy { !$0.startsParagraph })

        let collectedMetrics = metrics(outcome.events)
        #expect(collectedMetrics.map(\.chunkIndex) == [0, 1])
        #expect(collectedMetrics.allSatisfy { $0.generationDuration == 0 })
        for metric in collectedMetrics {
            let emitted = audio.filter { $0.index == metric.chunkIndex }
                .reduce(0) { $0 + $1.samples.count }
            #expect(
                abs(metric.audioDuration - Double(emitted) / 8_000)
                    < 0.000_001
            )
        }
        #expect(session.streamCalls.map(\.text) == [
            "Alpha bravo charlie.", "Delta echo foxtrot.",
        ])
        #expect(startedChunks(outcome.events).map(\.text)
            == session.streamCalls.map(\.text))
    }

    @Test("Orpheus short-chunk limits and paragraph separation")
    func orpheusShortChunksThroughInterface() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "orpheus-3b-bf16")
        let text = "The first paragraph introduces one complete idea "
            + "in a measured voice and should never be joined to "
            + "unrelated material from another block.\n\n"
            + "The second paragraph continues with a distinct subject, "
            + "enough words to require several safe synthesis requests, "
            + "and a clear ending."

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: text)
            )
        )

        #expect(outcome.error == nil)
        #expect(kinds(outcome.events).last == "completed")
        let generationTexts = session.streamCalls.map(\.text)
        #expect(generationTexts.count >= 3)
        #expect(generationTexts.allSatisfy { $0.count <= 120 })
        #expect(generationTexts.contains {
            $0.hasPrefix("The second paragraph")
        })
        #expect(
            generationTexts.flatMap {
                $0.split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
        #expect(generationTexts.allSatisfy {
            !($0.contains("first paragraph")
                && $0.contains("second paragraph"))
        })
        #expect(startedChunks(outcome.events).map(\.text)
            == generationTexts)
        #expect(session.streamCalls.allSatisfy { $0.voice == "tara" })
    }

    @Test("Scripted text-fitting splits apply before generation")
    func fittingSplitsAppliedBeforeGeneration() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.scriptFittingCharacterLimit(40)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")
        let text = "Alpha bravo charlie delta echo. "
            + "Foxtrot golf hotel india juliett."

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: text)
            )
        )

        #expect(outcome.error == nil)
        #expect(session.fittingCallTexts.first == text)
        #expect(session.streamCalls.map(\.text) == [
            "Alpha bravo charlie delta echo.",
            "Foxtrot golf hotel india juliett.",
        ])
        #expect(startedChunks(outcome.events).map(\.text)
            == session.streamCalls.map(\.text))
        #expect(metrics(outcome.events).map(\.chunkIndex) == [0, 1])
    }

    @Test("Input-length failure before samples retries as subchunks without duplicated audio")
    func inputTooLongBeforeSamplesRetries() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueStreamFailure(.inputTooLong)
        session.enqueueStreamBatches([samples(800)])
        session.enqueueStreamBatches([samples(800)])
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")
        let text = "Alpha bravo charlie delta echo. "
            + "Foxtrot golf hotel india juliett."

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: text)
            )
        )

        #expect(outcome.error == nil)
        #expect(kinds(outcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "chunkStarted(0)", "audio(0)",
            "metrics(0)", "chunkStarted(1)", "audio(1)", "audio(1)",
            "metrics(1)", "completed",
        ])
        #expect(session.streamCalls.map(\.text) == [
            text,
            "Alpha bravo charlie delta echo.",
            "Foxtrot golf hotel india juliett.",
        ])
        #expect(startedChunks(outcome.events).map(\.text)
            == session.streamCalls.map(\.text))
        let totalSamples = audioChunks(outcome.events)
            .reduce(0) { $0 + $1.samples.count }
        #expect(totalSamples == 1_536)
    }

    @Test("Input-length failure after partial samples fails the request")
    func inputTooLongAfterPartialSamplesFails() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueStream(
            batches: [samples(800)],
            thenFailure: .inputTooLong
        )
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Alpha bravo charlie delta echo. "
                        + "Foxtrot golf hotel india juliett."
                )
            )
        )

        #expect(
            (outcome.error as? ScriptedSpeechModelError)
                == .inputTooLong
        )
        #expect(session.streamCalls.count == 1)
        #expect(kinds(outcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "audio(0)",
        ])
    }

    @Test("Generic generation failure surfaces without retry")
    func genericStreamFailureSurfacesWithoutRetry() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueStreamFailure(.generic)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: "Alpha bravo charlie.")
            )
        )

        #expect(
            (outcome.error as? ScriptedSpeechModelError)
                == .genericGeneration
        )
        #expect(session.streamCalls.count == 1)
        #expect(audioChunks(outcome.events).isEmpty)
        #expect(!kinds(outcome.events).contains("completed"))
    }

    @Test("Automatic stable anchor is chosen by language and reused as the reference")
    func automaticStableAnchorReusedAsReference() async throws {
        let anchorSamples = samples(120, value: 0.2)
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueOneShotSamples(anchorSamples)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "omnivoice")
        let anchorText = "La lumière du matin entrait doucement "
            + "dans la pièce calme, tandis que les oiseaux "
            + "chantaient au loin."

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Bonjour le monde.",
                    language: "fr-FR",
                    voiceDescription: "A warm French narrator.",
                    voiceMode: .automaticStable,
                    voiceTuning: VoiceSynthesisTuning(
                        preset: "natural",
                        parameters: ["temperature": 0.7]
                    )
                )
            )
        )

        #expect(outcome.error == nil)
        #expect(Array(kinds(outcome.events).prefix(4)) == [
            "loadingModel(omnivoice)", "modelLoaded(omnivoice)",
            "creatingArticleVoice", "chunkStarted(0)",
        ])
        let anchorCall = try #require(session.oneShotCalls.first)
        #expect(session.oneShotCalls.count == 1)
        #expect(anchorCall.text == anchorText)
        #expect(anchorCall.voice == "A warm French narrator.")
        #expect(!anchorCall.hasReference)
        #expect(anchorCall.language == "fr-FR")
        #expect(anchorCall.tuningPreset == "natural")
        #expect(anchorCall.tuningParameters == ["temperature": 0.7])
        #expect(anchorCall.seed == nil)
        #expect(anchorCall.allowTuningSelectedGeneration == false)

        let streamCall = try #require(session.streamCalls.first)
        #expect(session.streamCalls.count == 1)
        #expect(streamCall.voice == nil)
        #expect(streamCall.referenceSamples == anchorSamples)
        #expect(streamCall.referenceTranscript == anchorText)
        #expect(streamCall.language == "fr-FR")
        #expect(streamCall.seed == nil)
    }

    @Test("Preset voice is forwarded as the voice argument")
    func presetVoiceArgumentForwarded() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Alpha bravo charlie.",
                    voice: "am_adam"
                )
            )
        )

        #expect(outcome.error == nil)
        let call = try #require(session.streamCalls.first)
        #expect(call.voice == "am_adam")
        #expect(!call.hasReference)
        #expect(call.language == "en-US")
        #expect(call.tuningPreset == nil)
        #expect(call.seed == nil)
        #expect(session.appliedSpeakingPaces == [.natural])
    }

    @Test("Voice description is preferred as the voice argument")
    func voiceDescriptionArgumentPreferred() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "qwen3-17b-voicedesign-8bit")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Alpha bravo charlie.",
                    voiceDescription: "A deep cinematic narrator."
                )
            )
        )

        #expect(outcome.error == nil)
        let call = try #require(session.streamCalls.first)
        #expect(call.voice == "A deep cinematic narrator.")
        #expect(!call.hasReference)
    }

    @Test("Random-per-paragraph mode suppresses the reference and separates paragraphs")
    func randomPerParagraphSuppressesReference() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItSynthesisEngineTests"
        )
        defer { fixture.remove() }
        let referenceURL = try await writeReferenceFixture(
            sampleCount: 1_200,
            sourceSampleRate: 12_000,
            in: fixture
        )
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "First paragraph stays alone.\n\n"
                        + "Second paragraph speaks next.",
                    voiceMode: .randomPerParagraph,
                    voiceReference: VoiceReference(
                        audioURL: referenceURL,
                        transcript: "Reference words."
                    )
                )
            )
        )

        #expect(outcome.error == nil)
        #expect(session.streamCalls.map(\.text) == [
            "First paragraph stays alone.",
            "Second paragraph speaks next.",
        ])
        #expect(session.streamCalls.allSatisfy { !$0.hasReference })
        #expect(session.streamCalls.allSatisfy {
            $0.referenceTranscript == nil
        })
        #expect(session.streamCalls.allSatisfy {
            $0.voice == model.defaultVoice
        })
    }

    @Test("Paragraph pause inserts silence frames and a speech-start offset")
    func paragraphPauseFramesAndOffset() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(
            synthesizer,
            chunkTarget: 20,
            paragraphPause: 0.5
        )
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "First paragraph sentence here.\n\n"
                        + "Second paragraph sentence here."
                )
            )
        )

        #expect(outcome.error == nil)
        #expect(
            startedChunks(outcome.events)
                .allSatisfy(\.startsParagraph)
        )
        let audio = audioChunks(outcome.events)
        let firstParagraphAudio = audio.filter { $0.index == 0 }
        let secondParagraphAudio = audio.filter { $0.index == 1 }
        #expect(firstParagraphAudio.allSatisfy {
            $0.speechStartOffset == 0
        })
        let secondOffset = try #require(
            secondParagraphAudio.first?.speechStartOffset
        )
        #expect(abs(secondOffset - 0.508) < 0.000_001)
        let secondSamples = secondParagraphAudio
            .flatMap(\.samples)
        #expect(longestZeroRun(secondSamples) >= 4_000)
        #expect(audio.reduce(0) { $0 + $1.samples.count } == 5_600)
    }

    @Test("Chunk delay sleeps between chunks only")
    func chunkDelayOnlyBetweenChunks() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let clock = ControllableSynthesisClock()
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: clock
        )
        await configure(
            synthesizer,
            chunkTarget: 20,
            chunkDelay: 0.25
        )
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Alpha bravo charlie. Delta echo foxtrot. "
                        + "Golf hotel india."
                )
            )
        )

        #expect(outcome.error == nil)
        #expect(session.streamCalls.count == 3)
        #expect(clock.recordedSleeps == [
            .seconds(0.25), .seconds(0.25),
        ])
    }

    @Test("Cancellation mid-stream is cleanly superseded by the next request")
    func cancellationMidStreamSuperseded() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueGatedStream(batchesBeforeGate: [samples(800)])
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer, chunkTarget: 20)
        let model = try catalogModel(id: "kokoro-bf16")

        // The gated first chunk stops yielding when its task is
        // cancelled; the engine then re-checks cancellation before the
        // second chunk, which is where the request is cancelled.
        let firstStream = await synthesizer.synthesize(
            makeRequest(
                model: model,
                text: "First request speaks. Then it continues."
            )
        )
        #expect(await waitUntil { session.isWaitingAtGate })
        let secondStream = await synthesizer.synthesize(
            makeRequest(model: model, text: "Second request speaks.")
        )
        let firstOutcome = await collectAll(firstStream)
        let secondOutcome = await collectAll(secondStream)

        #expect(firstOutcome.error != nil)
        #expect(kinds(firstOutcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "audio(0)", "metrics(0)", "cancelled",
        ])
        #expect(secondOutcome.error == nil)
        #expect(kinds(secondOutcome.events) == [
            "chunkStarted(0)", "audio(0)", "audio(0)", "metrics(0)",
            "completed",
        ])
        #expect(session.streamCalls.map(\.text) == [
            "First request speaks.", "Second request speaks.",
        ])
        #expect(loader.loadCount == 1)
        #expect(session.shutdownCount == 0)
        #expect(!session.isWaitingAtGate)
    }

    @Test("Unload during an active operation cancels it and forces a reload")
    func unloadDuringActiveOperation() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueGatedStream(batchesBeforeGate: [samples(800)])
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer, chunkTarget: 20)
        let model = try catalogModel(id: "kokoro-bf16")

        let firstStream = await synthesizer.synthesize(
            makeRequest(
                model: model,
                text: "Unload interrupts this. Then it continues."
            )
        )
        #expect(await waitUntil { session.isWaitingAtGate })
        await synthesizer.unloadModel()
        #expect(session.shutdownCount == 1)

        let firstOutcome = await collectAll(firstStream)
        #expect(firstOutcome.error != nil)
        #expect(kinds(firstOutcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
            "chunkStarted(0)", "audio(0)", "metrics(0)", "cancelled",
        ])

        let secondOutcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: "After unload speaks.")
            )
        )
        #expect(secondOutcome.error == nil)
        #expect(Array(kinds(secondOutcome.events).prefix(2)) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
        ])
        #expect(loader.loadCount == 2)
        #expect(session.streamCalls.map(\.text) == [
            "Unload interrupts this.", "After unload speaks.",
        ])
    }

    @Test("Idle unload fires when the clock advances past the delay")
    func idleUnloadWhenClockAdvances() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let clock = ControllableSynthesisClock(autoAdvance: false)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: clock
        )
        await configure(synthesizer, idleUnloadDelay: 5)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: "Alpha bravo charlie.")
            )
        )
        #expect(outcome.error == nil)
        #expect(
            await waitUntil {
                clock.recordedSleeps == [.seconds(5)]
            }
        )
        clock.advance(by: .seconds(4))
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(session.shutdownCount == 0)
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { session.shutdownCount == 1 })
    }

    @Test("New work cancels a pending idle unload")
    func idleUnloadCancelledByNewWork() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let clock = ControllableSynthesisClock(autoAdvance: false)
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(loader: loader, clock: clock)
        await configure(synthesizer, idleUnloadDelay: 5)
        let model = try catalogModel(id: "kokoro-bf16")

        let firstOutcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: "First speaks.")
            )
        )
        #expect(firstOutcome.error == nil)
        #expect(
            await waitUntil {
                clock.recordedSleeps == [.seconds(5)]
            }
        )

        let secondOutcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(model: model, text: "Second speaks.")
            )
        )
        #expect(secondOutcome.error == nil)
        #expect(!kinds(secondOutcome.events).contains {
            $0.hasPrefix("loadingModel")
        })
        #expect(
            await waitUntil { clock.recordedSleeps.count == 2 }
        )
        #expect(session.shutdownCount == 0)
        #expect(loader.loadCount == 1)

        await synthesizer.unloadModel()
        #expect(session.shutdownCount == 1)
    }

    @Test("Voice samples forward tuning and seed at the session sample rate")
    func voiceSampleForwardsTuningAndSeed() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 16_000)
        session.enqueueOneShotSamples([0.25, -0.5, 0.75])
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let result = try await synthesizer.generateVoiceSample(
            model: model,
            text: "Sample words.",
            language: "en-GB",
            tuning: VoiceSynthesisTuning(
                preset: "expressive",
                parameters: ["temperature": 0.7, "topP": 0.9]
            ),
            seed: 42
        )

        #expect(result.samples == [0.25, -0.5, 0.75])
        #expect(result.sampleRate == 16_000)
        let call = try #require(session.oneShotCalls.first)
        #expect(session.oneShotCalls.count == 1)
        #expect(call.text == "Sample words.")
        #expect(call.voice == nil)
        #expect(!call.hasReference)
        #expect(call.language == "en-GB")
        #expect(call.tuningPreset == "expressive")
        #expect(
            call.tuningParameters
                == ["temperature": 0.7, "topP": 0.9]
        )
        #expect(call.seed == 42)
        #expect(call.allowTuningSelectedGeneration == true)
        #expect(loader.loadedModelIDs == [model.id])
        #expect(session.quiesceCount == 1)
        #expect(session.shutdownCount == 0)
    }

    @Test("Voice samples fail when the model generates no audio")
    func voiceSampleEmptyOutputFails() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueOneShotSamples([])
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        do {
            _ = try await synthesizer.generateVoiceSample(
                model: model,
                text: "Sample words.",
                language: model.defaultLanguage,
                tuning: VoiceSynthesisTuning(
                    preset: "natural",
                    parameters: [:]
                ),
                seed: 1
            )
            Issue.record("Expected empty voice sample to fail")
        } catch let error as SynthesisError {
            #expect(
                error.errorDescription
                    == "The voice model did not generate playable audio."
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(session.oneShotCalls.count == 1)
    }

    @Test("Voice samples surface generic one-shot generation failures")
    func voiceSampleGenericFailureSurfaces() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueOneShotFailure(.generic)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        await #expect(throws: ScriptedSpeechModelError.self) {
            _ = try await synthesizer.generateVoiceSample(
                model: model,
                text: "Sample words.",
                language: model.defaultLanguage,
                tuning: VoiceSynthesisTuning(
                    preset: "natural",
                    parameters: [:]
                ),
                seed: 3
            )
        }
        #expect(session.oneShotCalls.count == 1)
    }

    @Test("Dependency preparation forwards to the loader")
    func dependencyPreparationForwarded() async throws {
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let loader = ScriptedSpeechModelLoader(session: session)
        let synthesizer = makeSynthesizer(
            loader: loader,
            clock: ControllableSynthesisClock()
        )
        let model = try catalogModel(id: "kokoro-bf16")

        try await synthesizer.prepareDependencies(for: model)
        #expect(loader.preparedModelIDs == [model.id])

        loader.failPrepareDependencies()
        await #expect(throws: ScriptedSpeechModelError.self) {
            try await synthesizer.prepareDependencies(for: model)
        }
        #expect(loader.preparedModelIDs == [model.id, model.id])
    }

    @Test("Reference files decode to the session sample rate and suppress the voice argument")
    func referenceFileDecodedToSessionSampleRate() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItSynthesisEngineTests"
        )
        defer { fixture.remove() }
        let referenceURL = try await writeReferenceFixture(
            sampleCount: 1_200,
            sourceSampleRate: 12_000,
            in: fixture
        )
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Speak like the reference.",
                    voiceMode: .savedProfile,
                    voiceReference: VoiceReference(
                        audioURL: referenceURL,
                        transcript: "Reference words."
                    )
                )
            )
        )

        #expect(outcome.error == nil)
        #expect(kinds(outcome.events).last == "completed")
        let call = try #require(session.streamCalls.first)
        #expect(call.voice == nil)
        #expect(call.referenceTranscript == "Reference words.")
        let decoded = try #require(call.referenceSamples)
        #expect(decoded.count == 800)
        #expect(decoded.allSatisfy(\.isFinite))
        #expect((decoded.map { abs($0) }.max() ?? 0) > 0.1)
    }

    @Test("Invalid reference files fail before any generation")
    func invalidReferenceFileFails() async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItSynthesisEngineTests"
        )
        defer { fixture.remove() }
        let referenceURL = fixture.root.appending(path: "reference.wav")
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )
        try Data("not audio".utf8).write(to: referenceURL)
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let outcome = await collectAll(
            await synthesizer.synthesize(
                makeRequest(
                    model: model,
                    text: "Speak like the reference.",
                    voiceMode: .savedProfile,
                    voiceReference: VoiceReference(
                        audioURL: referenceURL,
                        transcript: "Reference words."
                    )
                )
            )
        )

        #expect(outcome.error != nil)
        #expect(kinds(outcome.events) == [
            "loadingModel(kokoro-bf16)", "modelLoaded(kokoro-bf16)",
        ])
        #expect(session.generationCalls.isEmpty)
        #expect(session.fittingCallTexts.isEmpty)
    }

    @Test("Streaming interval follows the request model's playback mode")
    func streamingIntervalByPlaybackMode() async throws {
        let progressiveSession =
            ScriptedSpeechModelSession(sampleRate: 8_000)
        let progressiveSynthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(
                session: progressiveSession
            ),
            clock: ControllableSynthesisClock()
        )
        await configure(progressiveSynthesizer)
        let progressive = try catalogModel(id: "kokoro-bf16")

        let progressiveRun = await collectAll(
            await progressiveSynthesizer.synthesize(
                makeRequest(
                    model: progressive,
                    text: "Alpha bravo charlie."
                )
            )
        )

        let bufferedSession =
            ScriptedSpeechModelSession(sampleRate: 8_000)
        let bufferedSynthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(
                session: bufferedSession
            ),
            clock: ControllableSynthesisClock()
        )
        await configure(bufferedSynthesizer)
        let buffered = try catalogModel(id: "qwen3-06b-base-8bit")

        let bufferedRun = await collectAll(
            await bufferedSynthesizer.synthesize(
                makeRequest(
                    model: buffered,
                    text: "Alpha bravo charlie."
                )
            )
        )

        #expect(progressiveRun.error == nil)
        #expect(bufferedRun.error == nil)
        #expect(
            progressiveSession.streamCalls.first?.streamingInterval
                == 0.32
        )
        #expect(
            bufferedSession.streamCalls.first?.streamingInterval == 2
        )
    }

    @Test("Voice samples decode the reference to the session sample rate")
    func voiceSampleReferenceDecodedToSessionSampleRate()
        async throws {
        let fixture = try TemporaryBackendFixture(
            prefix: "SayItSynthesisEngineTests"
        )
        defer { fixture.remove() }
        let referenceURL = try await writeReferenceFixture(
            sampleCount: 1_200,
            sourceSampleRate: 12_000,
            in: fixture
        )
        let session = ScriptedSpeechModelSession(sampleRate: 8_000)
        session.enqueueOneShotSamples([0.25, -0.5, 0.75])
        let synthesizer = makeSynthesizer(
            loader: ScriptedSpeechModelLoader(session: session),
            clock: ControllableSynthesisClock()
        )
        await configure(synthesizer)
        let model = try catalogModel(id: "kokoro-bf16")

        let result = try await synthesizer.generateVoiceSample(
            model: model,
            text: "Sample words.",
            language: "en-GB",
            tuning: VoiceSynthesisTuning(
                preset: "expressive",
                parameters: ["temperature": 0.7]
            ),
            seed: 42,
            reference: VoiceReference(
                audioURL: referenceURL,
                transcript: "Reference words."
            )
        )

        #expect(result.samples == [0.25, -0.5, 0.75])
        #expect(result.sampleRate == 8_000)
        let call = try #require(session.oneShotCalls.first)
        #expect(session.oneShotCalls.count == 1)
        #expect(call.voice == nil)
        #expect(call.referenceTranscript == "Reference words.")
        let decoded = try #require(call.referenceSamples)
        #expect(decoded.count == 800)
        #expect(decoded.allSatisfy(\.isFinite))
        #expect((decoded.map { abs($0) }.max() ?? 0) > 0.1)
        #expect(call.allowTuningSelectedGeneration == true)
    }

    // MARK: - Harness

    private func makeSynthesizer(
        loader: ScriptedSpeechModelLoader,
        clock: ControllableSynthesisClock
    ) -> SynthesisActor {
        SynthesisActor(
            modelURLProvider: { _ in URL(filePath: "/tmp/scripted-model") },
            loader: loader,
            clock: clock
        )
    }

    private func configure(
        _ synthesizer: SynthesisActor,
        chunkTarget: Int = 650,
        chunkDelay: Double = 0,
        paragraphPause: Double = 0,
        idleUnloadDelay: Double = 0
    ) async {
        await synthesizer.updateConfiguration(
            chunkTarget: chunkTarget,
            chunkDelay: chunkDelay,
            paragraphPause: paragraphPause,
            idleUnloadDelay: idleUnloadDelay
        )
    }

    private func makeRequest(
        model: ModelDescriptor,
        text: String,
        voice: String? = nil,
        language: String? = nil,
        voiceDescription: String? = nil,
        voiceMode: VoiceSynthesisMode = .standard,
        voiceReference: VoiceReference? = nil,
        voiceTuning: VoiceSynthesisTuning? = nil
    ) -> SpeechRequest {
        SpeechRequest(
            cleanedText: CleanedText(
                text: text,
                title: "Synthesis engine test",
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: voice ?? model.defaultVoice,
            language: language ?? model.defaultLanguage,
            voiceDescription: voiceDescription,
            voiceMode: voiceMode,
            voiceReference: voiceReference,
            voiceTuning: voiceTuning,
            source: .frontend
        )
    }

    private func catalogModel(id: String) throws -> ModelDescriptor {
        try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
                $0.id.rawValue == id
            }
        )
    }

    private func samples(_ count: Int, value: Float = 0.1) -> [Float] {
        [Float](repeating: value, count: count)
    }

    private func writeReferenceFixture(
        sampleCount: Int,
        sourceSampleRate: Double,
        in fixture: TemporaryBackendFixture
    ) async throws -> URL {
        // Sawtooth between -0.2 and 0.2 so decoded samples are finite
        // and audibly non-silent without any math-library dependency.
        let samples = (0..<sampleCount).map { frame in
            Float(frame % 100) / 100 * 0.4 - 0.2
        }
        let url = fixture.root.appending(path: "reference.wav")
        try await AudioArchive(directory: fixture.root).writeWAV(
            samples: samples,
            sampleRate: sourceSampleRate,
            destination: url
        )
        return url
    }

    private func collectAll(
        _ stream: AsyncThrowingStream<SynthesisEvent, Error>
    ) async -> (events: [SynthesisEvent], error: Error?) {
        var events: [SynthesisEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<100_000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func kinds(_ events: [SynthesisEvent]) -> [String] {
        events.map { event in
            switch event {
            case .loadingModel(let id):
                return "loadingModel(\(id.rawValue))"
            case .modelLoaded(let id):
                return "modelLoaded(\(id.rawValue))"
            case .creatingArticleVoice:
                return "creatingArticleVoice"
            case .chunkStarted(let index, _):
                return "chunkStarted(\(index))"
            case .audio(let chunk):
                return "audio(\(chunk.index))"
            case .metrics(let metrics):
                return "metrics(\(metrics.chunkIndex))"
            case .completed:
                return "completed"
            case .cancelled:
                return "cancelled"
            }
        }
    }

    private func audioChunks(
        _ events: [SynthesisEvent]
    ) -> [AudioChunk] {
        events.compactMap { event in
            if case .audio(let chunk) = event {
                return chunk
            }
            return nil
        }
    }

    private func metrics(
        _ events: [SynthesisEvent]
    ) -> [SynthesisMetrics] {
        events.compactMap { event in
            if case .metrics(let metrics) = event {
                return metrics
            }
            return nil
        }
    }

    private func startedChunks(
        _ events: [SynthesisEvent]
    ) -> [SpeechChunk] {
        events.compactMap { event in
            if case .chunkStarted(_, let chunk) = event {
                return chunk
            }
            return nil
        }
    }

    private func longestZeroRun(_ samples: [Float]) -> Int {
        var longest = 0
        var current = 0
        for sample in samples {
            if sample == 0 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
