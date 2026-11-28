import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Synthesis actor lifecycle")
struct SynthesisActorTests {
    @Test("Missing model URLs fail voice samples without loading MLX")
    func missingVoiceSampleModel() async throws {
        let requestedIDs = ModelIDRecorder()
        let synthesizer = SynthesisActor { id in
            await requestedIDs.append(id)
            return nil
        }
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )

        await #expect(throws: SynthesisError.self) {
            _ = try await synthesizer.generateVoiceSample(
                model: model,
                text: "Sample",
                language: model.defaultLanguage,
                tuning: VoiceSynthesisTuning(
                    preset: "natural",
                    parameters: [:]
                ),
                seed: 7
            )
        }
        #expect(await requestedIDs.values == [model.id])
        await synthesizer.cancelCurrentRequest()
        await synthesizer.unloadModel()
    }

    @Test("Synthesis streams loading then surface missing installations")
    func missingModelStream() async throws {
        let synthesizer = SynthesisActor { _ in nil }
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )
        let request = SpeechRequest(
            cleanedText: CleanedText(
                text: "Short text.",
                title: "Short text",
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: model.defaultVoice,
            language: model.defaultLanguage,
            source: .frontend
        )
        let stream = await synthesizer.synthesize(request)
        var events: [SynthesisEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            Issue.record("Expected synthesis to fail")
        } catch let error as SynthesisError {
            #expect(error.errorDescription?.contains("not installed") == true)
        }
        #expect(events.contains { event in
            if case .loadingModel(let id) = event { return id == model.id }
            return false
        })
    }

    @Test("Configuration clamps negative timing and supports dependency-free models")
    func configurationAndDependencyPreparation() async throws {
        let synthesizer = SynthesisActor { _ in nil }
        await synthesizer.updateConfiguration(
            chunkTarget: 1,
            chunkDelay: -1,
            paragraphPause: -1,
            idleUnloadDelay: -1
        )
        let qwen = try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
                $0.modelType.lowercased() == "qwen3_tts"
            }
        )
        try await synthesizer.prepareDependencies(for: qwen)
        await synthesizer.cancelCurrentRequest()
        await synthesizer.unloadModel()
    }

    @Test("Orpheus long form stays below its audio-token ceiling")
    func orpheusLongFormChunking() {
        let text = """
        The first paragraph introduces one complete idea in a measured voice and should never be joined to unrelated material from another block.

        The second paragraph continues with a distinct subject, enough words to require several safe synthesis requests, and a clear ending.
        """
        let chunks = SynthesisActor.orpheusChunker.chunks(
            for: text,
            separatesParagraphs: true
        )

        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.text.count <= 120 })
        #expect(chunks.contains { $0.text.hasPrefix("The second paragraph") })
        #expect(
            chunks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
                == text.split(whereSeparator: \.isWhitespace)
        )
    }

    @Test("Mono reference resampling matches scalar linear interpolation including the final sample")
    func resampleMonoEndpointParity() {
        let input: [Float] = (0..<17).map { index in
            sin(Float(index) * 0.37) + Float(index) * 0.05
        }
        for (sourceRate, targetRate) in [(16_000.0, 24_000.0), (44_100.0, 24_000.0), (24_000.0, 44_100.0)] {
            let resampled = SynthesisActor.resampleMono(
                input,
                from: sourceRate,
                to: targetRate
            )
            let expectedCount = max(Int(Double(input.count) * targetRate / sourceRate), 1)
            #expect(resampled.count == expectedCount)
            let step = Float(sourceRate / targetRate)
            for outIndex in 0..<expectedCount {
                let rawPos = Float(outIndex) * step
                let clamped = min(max(rawPos, 0), Float(input.count - 1))
                let lo = Int(floor(clamped))
                let hi = min(lo + 1, input.count - 1)
                let frac = clamped - Float(lo)
                let expected = input[lo] + (input[hi] - input[lo]) * frac
                #expect(abs(resampled[outIndex] - expected) < 1e-5)
            }
            #expect(resampled.allSatisfy { $0.isFinite })
        }

        // Single-sample and matching-rate edge cases.
        #expect(SynthesisActor.resampleMono([0.42], from: 16_000, to: 24_000) == [0.42])
        #expect(SynthesisActor.resampleMono(input, from: 24_000, to: 24_000) == input)
        #expect(SynthesisActor.resampleMono([], from: 16_000, to: 24_000).isEmpty)
    }

    @Test("Automatic voice anchor policy covers single-chunk, threshold boundaries, and retry splits")
    func automaticStableAnchorPolicy() {
        // Single-chunk requests skip anchor synthesis altogether.
        #expect(
            SynthesisActor.automaticStableAnchorAction(
                voiceMode: .automaticStable,
                supportsRandomVoiceSampling: true,
                hasReferenceAudio: false,
                chunkCount: 1,
                firstChunkLength: 100
            ) == .none
        )
        // Multi-chunk below the 36-char threshold synthesizes an upfront anchor.
        #expect(
            SynthesisActor.automaticStableAnchorAction(
                voiceMode: .automaticStable,
                supportsRandomVoiceSampling: true,
                hasReferenceAudio: false,
                chunkCount: 2,
                firstChunkLength: 35
            ) == .synthesizeAnchorUpfront
        )
        // Multi-chunk at or above 36 chars self-anchors on chunk 0.
        #expect(
            SynthesisActor.automaticStableAnchorAction(
                voiceMode: .automaticStable,
                supportsRandomVoiceSampling: true,
                hasReferenceAudio: false,
                chunkCount: 2,
                firstChunkLength: 36
            ) == .selfAnchorFirstChunk
        )
        // Existing reference audio or non-automatic modes never re-anchor.
        #expect(
            SynthesisActor.automaticStableAnchorAction(
                voiceMode: .automaticStable,
                supportsRandomVoiceSampling: true,
                hasReferenceAudio: true,
                chunkCount: 3,
                firstChunkLength: 40
            ) == .none
        )
        #expect(
            SynthesisActor.automaticStableAnchorAction(
                voiceMode: .standard,
                supportsRandomVoiceSampling: true,
                hasReferenceAudio: false,
                chunkCount: 3,
                firstChunkLength: 40
            ) == .none
        )
    }

    @Test("Qwen3 conditioning cache only stores persistent saved profiles")
    func qwen3ConditioningCachePolicy() {
        #expect(SynthesisActor.shouldCacheQwen3Conditioning(voiceMode: .savedProfile))
        #expect(!SynthesisActor.shouldCacheQwen3Conditioning(voiceMode: .automaticStable))
        #expect(!SynthesisActor.shouldCacheQwen3Conditioning(voiceMode: .standard))
        #expect(!SynthesisActor.shouldCacheQwen3Conditioning(voiceMode: .randomPerParagraph))
    }

    @Test("Pre-cancelled synthesis or voice-sample caller does not preempt active operation")
    func preCancelledCallerDoesNotPreemptActiveOperation() async throws {
        let gate = SynthesisActorCancellationGate()
        let synthesizer = SynthesisActor { _ in
            await gate.wait()
            return nil
        }
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )
        let request = SpeechRequest(
            cleanedText: CleanedText(
                text: "Active request.",
                title: "Active request",
                detectedLanguage: "en",
                cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                requiresLongTextConfirmation: false
            ),
            model: model,
            voice: model.defaultVoice,
            language: model.defaultLanguage,
            source: .frontend
        )

        let activeStream = await synthesizer.synthesize(request)
        let activeTask = Task { () -> Bool in
            do {
                for try await _ in activeStream {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await gate.waitUntilEntered()

        let cancelledSynthTask = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let stream = await synthesizer.synthesize(request)
            do {
                for try await _ in stream {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await cancelledSynthTask.value)

        let cancelledSampleTask = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await synthesizer.generateVoiceSample(
                    model: model,
                    text: "Sample",
                    language: model.defaultLanguage,
                    tuning: VoiceSynthesisTuning(preset: "natural", parameters: [:]),
                    seed: 1
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await cancelledSampleTask.value)

        // The original operation must still be running, uncancelled.
        #expect(!(await gate.observedCancellation))
        await gate.release()
        #expect(!(await activeTask.value))
    }
}

private actor SynthesisActorCancellationGate {
    private var entered = false
    private var released = false
    private(set) var observedCancellation = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for waiter in enterWaiters { waiter.resume() }
        enterWaiters.removeAll()
        if released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.markCancelled() }
        }
    }

    private func markCancelled() {
        observedCancellation = true
        release()
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ModelIDRecorder {
    private(set) var values: [ModelID] = []

    func append(_ value: ModelID) {
        values.append(value)
    }
}
