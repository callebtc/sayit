import Foundation
import Testing
@testable import SayItCore

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("Bundled catalog is valid and immutable")
    func bundledCatalogIsValid() throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()

        #expect(catalog.models.count == 16)
        #expect(catalog.models.first?.id == ModelID("kokoro-bf16"))
        #expect(catalog.models.allSatisfy { $0.revision.count == 40 })
        #expect(catalog.models.allSatisfy {
            $0.testedMLXAudioVersion == "0.1.3"
        })
    }

    @Test("Only Kokoro and Qwen are recommended")
    func recommendedModelsAndRanking() throws {
        let models = try ModelCatalogLoader().bundledCatalog().models
        let recommended = models
            .filter { $0.stability == .recommended }
            .sorted {
                ($0.experience?.recommendationRank ?? .max)
                    < ($1.experience?.recommendationRank ?? .max)
            }

        #expect(recommended.map(\.id.rawValue) == [
            "kokoro-bf16",
            "qwen3-06b-base-8bit",
        ])

        let ranked = models
            .compactMap { model in
                model.experience.map { ($0.recommendationRank, model.id) }
            }
            .sorted { $0.0 < $1.0 }
        #expect(ranked.prefix(3).map { $0.1.rawValue } == [
            "kokoro-bf16",
            "qwen3-06b-base-8bit",
            "pocket-tts",
        ])
    }

    @Test("Legacy unsupported downloads remain unavailable")
    func legacyUnsupportedModels() throws {
        let models = Dictionary(
            uniqueKeysWithValues: try ModelCatalogLoader()
                .bundledCatalog()
                .models
                .map { ($0.id.rawValue, $0) }
        )

        for id in ["omnivoice", "moss-tts", "marvis-250m-8bit"] {
            #expect(models[id]?.stability == .unavailable)
            #expect(models[id]?.isSelectable == false)
        }
    }

    @Test("Reference-only models cannot be selected")
    func gatesReferenceAudioModels() throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let gated = catalog.models.filter {
            $0.capabilities.requiresReferenceAudio
        }

        #expect(gated.count == 4)
        #expect(gated.map(\.id.rawValue).sorted() == [
            "echo-base",
            "fish-s2-pro-8bit",
            "index-tts",
            "moss-nano-100m",
        ])
        #expect(gated.allSatisfy { !$0.isSelectable })
    }

    @Test("Hardware warning uses the seventy-percent boundary")
    func hardwareWarning() throws {
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )
        let advisor = HardwareAdvisor()

        #expect(
            advisor.suitability(
                for: model,
                physicalMemory: 16_000_000_000
            ) == .recommended
        )
        #expect(
            advisor.requiresMemoryConfirmation(
                for: model,
                physicalMemory: 1_500_000_000
            )
        )
    }

    @Test("Only verified native models advertise speaking pace")
    func nativeSpeakingPaceSupport() throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let supportedIDs = catalog.models
            .filter(\.supportsNativeSpeakingPace)
            .map(\.id)

        #expect(supportedIDs == [ModelID("kokoro-bf16")])
    }

    @Test("Kokoro preset prefixes select their matching language")
    func kokoroPresetLanguages() throws {
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first {
                $0.id == ModelID("kokoro-bf16")
            }
        )

        #expect(model.inferredLanguage(forPresetVoice: "af_heart") == "en-US")
        #expect(model.inferredLanguage(forPresetVoice: "bm_george") == "en-GB")
        #expect(model.inferredLanguage(forPresetVoice: "ef_dora") == "es")
        #expect(model.inferredLanguage(forPresetVoice: "ff_siwis") == "fr")
        #expect(model.inferredLanguage(forPresetVoice: "jf_alpha") == "ja")
        #expect(model.inferredLanguage(forPresetVoice: "zm_yunxi") == "cmn")
    }

    @Test("Generated and cloned voice capabilities are explicitly routed")
    func voiceCapabilities() throws {
        let models = Dictionary(
            uniqueKeysWithValues: try ModelCatalogLoader()
                .bundledCatalog()
                .models
                .map { ($0.id.rawValue, $0) }
        )
        for id in [
            "qwen3-06b-base-8bit",
            "omnivoice",
            "fish-s2-pro-8bit"
        ] {
            let model = try #require(models[id])
            #expect(model.capabilities.supportsVoiceDiscovery)
            #expect(model.capabilities.supportsRandomVoiceSampling)
            #expect(model.capabilities.voiceCloning)
            #expect(model.capabilities.voiceCloneRequirements != nil)
        }

        let chatterbox = try #require(models["chatterbox-fp16"])
        #expect(!chatterbox.capabilities.supportsVoiceDiscovery)
        #expect(!chatterbox.capabilities.supportsRandomVoiceSampling)
        #expect(chatterbox.capabilities.voiceCloning)
        #expect(chatterbox.capabilities.voiceCloneRequirements != nil)

        let kokoro = try #require(models["kokoro-bf16"])
        #expect(!kokoro.capabilities.supportsVoiceDiscovery)
        #expect(!kokoro.capabilities.supportsRandomVoiceSampling)
        #expect(!kokoro.capabilities.voiceCloning)
        #expect(kokoro.capabilities.voiceCloneRequirements == nil)
    }
}
