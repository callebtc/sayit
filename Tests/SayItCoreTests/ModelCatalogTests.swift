import Foundation
import Testing
@testable import SayItCore

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("Bundled catalog is valid and immutable")
    func bundledCatalogIsValid() throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()

        #expect(catalog.models.count == 24)
        #expect(catalog.models.first?.id == ModelID("kokoro-bf16"))
        #expect(catalog.models.allSatisfy { $0.revision.count == 40 })
        #expect(catalog.models.allSatisfy {
            ["0.1.3", "bf14ae0"].contains($0.testedMLXAudioVersion)
        })
    }

    @Test("Hands-on recommendations lead the ranked catalog")
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
            "qwen3-17b-customvoice-8bit",
            "omnivoice",
        ])

        let ranked = models
            .compactMap { model in
                model.experience.map { ($0.recommendationRank, model.id) }
            }
            .sorted { $0.0 < $1.0 }
        #expect(ranked.prefix(4).map { $0.1.rawValue } == [
            "kokoro-bf16",
            "qwen3-06b-base-8bit",
            "qwen3-17b-customvoice-8bit",
            "omnivoice",
        ])
        #expect(ranked.map(\.0) == Array(1...ranked.count))
    }

    @Test("Legacy unsupported downloads remain unavailable")
    func legacyUnsupportedModels() throws {
        let models = Dictionary(
            uniqueKeysWithValues: try ModelCatalogLoader()
                .bundledCatalog()
                .models
                .map { ($0.id.rawValue, $0) }
        )

        for id in ["moss-tts", "marvis-250m-8bit"] {
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

        #expect(gated.count == 5)
        #expect(gated.map(\.id.rawValue).sorted() == [
            "echo-base",
            "fish-s2-pro-8bit",
            "index-tts",
            "index-tts-15",
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
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let models = Dictionary(
            uniqueKeysWithValues: catalog.models.map { ($0.id.rawValue, $0) }
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

        let omniVoice = try #require(models["omnivoice"])
        #expect(omniVoice.repository == "mlx-community/OmniVoice-bfloat16")
        #expect(omniVoice.quantization == "BF16")
        #expect(omniVoice.stability == .recommended)

        let kittenNano = try #require(models["kitten-nano-08-4bit"])
        #expect(kittenNano.voices.count == 8)
        #expect(kittenNano.defaultVoice == "Jasper")
        #expect(kittenNano.estimatedDiskBytes == 34_000_000)

        let orpheus4Bit = try #require(models["orpheus-3b-4bit"])
        #expect(orpheus4Bit.voices.count == 8)
        #expect(orpheus4Bit.defaultVoice == "tara")
        #expect(orpheus4Bit.quantization == "4-bit")

        let chatterbox = try #require(models["chatterbox-fp16"])
        #expect(!chatterbox.capabilities.supportsVoiceDiscovery)
        #expect(!chatterbox.capabilities.supportsRandomVoiceSampling)
        #expect(chatterbox.capabilities.voiceCloning)
        #expect(chatterbox.capabilities.voiceCloneRequirements != nil)

        let voiceDesign = try #require(
            models["qwen3-17b-voicedesign-8bit"]
        )
        #expect(voiceDesign.capabilities.voiceDescription)
        #expect(voiceDesign.capabilities.presetVoices)
        #expect(!voiceDesign.capabilities.voiceCloning)
        #expect(!voiceDesign.capabilities.supportsRandomVoiceSampling)
        #expect(voiceDesign.voices.count == 6)
        #expect(voiceDesign.defaultVoice == "Warm storyteller")

        let customVoice = try #require(
            models["qwen3-17b-customvoice-8bit"]
        )
        #expect(customVoice.capabilities.presetVoices)
        #expect(customVoice.capabilities.voiceCloning)
        #expect(!customVoice.capabilities.supportsRandomVoiceSampling)
        #expect(customVoice.defaultVoice == "ryan")
        #expect(customVoice.stability == .recommended)

        let chatterboxTurbo = try #require(models["chatterbox-turbo-fp16"])
        #expect(chatterboxTurbo.modelType == "chatterbox_turbo")
        #expect(chatterboxTurbo.capabilities.voiceCloning)
        #expect(!chatterboxTurbo.capabilities.requiresReferenceAudio)
        #expect(!chatterboxTurbo.capabilities.supportsRandomVoiceSampling)
        let chatterboxConditioning = try #require(
            catalog.dependencies.first {
                $0.id == "chatterbox-default-conditioning"
            }
        )
        #expect(!chatterboxConditioning.modelTypes.contains("chatterbox_turbo"))

        let chatterboxMultilingual = try #require(
            models["chatterbox-multilingual-v3-fp16"]
        )
        #expect(chatterboxMultilingual.languages.count == 23)
        #expect(chatterboxMultilingual.capabilities.languageSelection)
        #expect(chatterboxMultilingual.capabilities.voiceCloning)
        #expect(!chatterboxMultilingual.capabilities.requiresReferenceAudio)

        let kokoro = try #require(models["kokoro-bf16"])
        #expect(!kokoro.capabilities.supportsVoiceDiscovery)
        #expect(!kokoro.capabilities.supportsRandomVoiceSampling)
        #expect(!kokoro.capabilities.voiceCloning)
        #expect(kokoro.capabilities.voiceCloneRequirements == nil)
    }
}
