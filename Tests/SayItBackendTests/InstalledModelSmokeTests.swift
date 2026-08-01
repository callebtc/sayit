import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Installed model smoke tests", .serialized)
struct InstalledModelSmokeTests {
    @Test("Configured model completes its production download")
    func configuredModelCompletesDownload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelID = environment["SAYIT_MODEL_AUDIT_INSTALL_ID"] else {
            return
        }

        let catalog = try ModelCatalogLoader().bundledCatalog()
        let model = try #require(catalog.models.first {
            $0.id.rawValue == modelID
        })
        let directories = try AppDirectories.shared(
            appGroupIdentifier: "app.sayit.audit"
        )
        let manager = ModelManager(
            catalog: catalog,
            directories: directories,
            activeModelID: ModelID("model-audit")
        )
        try await manager.install(model.id)
        try await manager.markDependenciesVerified(model.id)

        #expect(await manager.installedURL(for: model.id) != nil)
        print("MODEL_AUDIT_INSTALL_RESULT id=\(model.id.rawValue) installed=true")
    }

    @Test("Configured model generates finite, audible samples")
    func configuredModelGeneratesAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelID = environment["SAYIT_MODEL_AUDIT_ID"],
              let modelsRoot = environment["SAYIT_MODEL_AUDIT_ROOT"] else {
            return
        }

        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
                $0.id.rawValue == modelID
            }
        )
        let modelsRootURL = URL(filePath: modelsRoot, directoryHint: .isDirectory)
        setenv(
            "HF_HUB_CACHE",
            modelsRootURL.deletingLastPathComponent()
                .appending(path: "Hugging Face", directoryHint: .isDirectory)
                .path,
            1
        )
        let modelURL = modelsRootURL
            .appending(path: model.id.rawValue, directoryHint: .isDirectory)
            .appending(path: model.revision, directoryHint: .isDirectory)
        let synthesizer = SynthesisActor { requestedID in
            requestedID == model.id ? modelURL : nil
        }
        let voiceReference = environment["SAYIT_MODEL_AUDIT_REFERENCE"].map {
            VoiceReference(
                audioURL: URL(filePath: $0),
                transcript: environment["SAYIT_MODEL_AUDIT_REFERENCE_TEXT"]
            )
        }
        let voices: [String?]
        if environment["SAYIT_MODEL_AUDIT_ALL_VOICES"] == "1",
           !model.voices.isEmpty {
            voices = model.voices.map(Optional.some)
        } else if let requestedVoice = environment["SAYIT_MODEL_AUDIT_VOICE"] {
            voices = [requestedVoice]
        } else {
            voices = [model.defaultVoice]
        }

        for voice in voices {
            let voiceName = voice ?? "none"
            let language = model.inferredLanguage(forPresetVoice: voice)
                ?? model.defaultLanguage
            let request = SpeechRequest(
                cleanedText: CleanedText(
                    text: sampleText(for: model, language: language),
                    title: "Model audit",
                    detectedLanguage: language ?? "en",
                    cleanupSummary: CleanupSummary(sourceFormat: "plainText"),
                    requiresLongTextConfirmation: false
                ),
                model: model,
                voice: voice,
                language: language,
                voiceDescription: model.capabilities.voiceDescription
                    ? "A calm, clear adult voice with natural pacing."
                    : nil,
                voiceMode: voiceReference == nil
                    ? model.capabilities.supportsRandomVoiceSampling
                        ? .automaticStable
                        : .standard
                    : .savedProfile,
                voiceReference: voiceReference,
                source: .preview
            )

            let startedAt = ContinuousClock.now
            let stream = await synthesizer.synthesize(request)
            var samples: [Float] = []
            var sampleRate = 0.0
            for try await event in stream {
                if case .audio(let chunk) = event {
                    samples.append(contentsOf: chunk.samples)
                    sampleRate = chunk.sampleRate
                }
            }

            let elapsed = startedAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let finiteSamples = samples.filter(\.isFinite)
            let peak = finiteSamples.map { abs($0) }.max() ?? 0
            let rms = finiteSamples.isEmpty
                ? 0
                : sqrt(
                    finiteSamples.reduce(0.0) { sum, sample in
                        sum + Double(sample * sample)
                    } / Double(finiteSamples.count)
                )
            let audioDuration = sampleRate > 0
                ? Double(samples.count) / sampleRate
                : 0
            print(
                "MODEL_AUDIT_RESULT id=\(model.id.rawValue) "
                    + "voice=\(voiceName) "
                    + "samples=\(samples.count) rate=\(sampleRate) "
                    + "duration=\(audioDuration) peak=\(peak) rms=\(rms) "
                    + "elapsed=\(seconds)"
            )

            #expect(samples.count > 1_000, "No audio for voice \(voiceName)")
            #expect(
                finiteSamples.count == samples.count,
                "Non-finite audio for voice \(voiceName)"
            )
            #expect(sampleRate >= 8_000, "Invalid rate for voice \(voiceName)")
            #expect(peak > 0.001, "Silent audio for voice \(voiceName)")
            #expect(rms > 0.0001, "Silent audio for voice \(voiceName)")
        }
        await synthesizer.unloadModel()
    }

    private func sampleText(
        for model: ModelDescriptor,
        language: String?
    ) -> String {
        switch language?.lowercased() {
        case "es":
            "Hoy es un día tranquilo. Esta es una prueba breve de una voz clara."
        case "fr":
            "Aujourd’hui est une journée calme. Ceci est un bref test vocal."
        case "ja":
            "今日は穏やかな一日です。自然で明瞭な声のテストをしています。"
        case "cmn", "zh":
            "今天是平静的一天。这是一次清晰自然的语音测试。"
        default:
            "Today is a calm day. This is a short test of clear, natural speech."
        }
    }
}
