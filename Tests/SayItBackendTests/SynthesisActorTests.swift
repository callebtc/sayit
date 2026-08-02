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
}

private actor ModelIDRecorder {
    private(set) var values: [ModelID] = []

    func append(_ value: ModelID) {
        values.append(value)
    }
}
