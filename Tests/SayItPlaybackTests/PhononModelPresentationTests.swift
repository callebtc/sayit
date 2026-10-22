import SayItCore
import Testing
@testable import SayIt
@testable import SayItBackend

@Suite("Phonon model presentation")
struct PhononModelPresentationTests {
    @Test("The voice picker hides undownloaded presets on an existing installation")
    func availablePresetOptions() throws {
        let model = try phononModel()
        let fresh = model.serviceSnapshot
        #expect(fresh.availableVoices == nil)
        #expect(fresh.descriptor.voices == model.voices)

        let legacy = model.serviceSnapshot(availableVoices: ["default"])
        #expect(legacy.voices.count == 38)
        #expect(legacy.descriptor.voices == ["default"])

        let updated = model.serviceSnapshot(availableVoices: model.voices)
        #expect(updated.descriptor.voices == model.voices)
        #expect(updated.descriptor.voices.count == 38)
    }

    @Test("Phonon exposes file import while keeping local clone and design controls hidden")
    func supportedVoiceControls() throws {
        let descriptor = try phononModel().serviceSnapshot.descriptor
        #expect(descriptor.isSelectable)
        #expect(descriptor.stability == .recommended)
        #expect(descriptor.supportsPhononVoiceImport)
        #expect(!descriptor.capabilities.voiceCloning)
        #expect(descriptor.capabilities.voiceCloneRequirements == nil)
        #expect(!descriptor.capabilities.voiceDescription)
        #expect(!descriptor.capabilities.supportsVoiceDiscovery)
    }

    @Test("Onboarding recommends Phonon first regardless of catalog order")
    @MainActor
    func onboardingRecommendation() throws {
        let models = try ModelCatalogLoader().bundledCatalog().models
        #expect(
            VoiceOnboardingView.recommendedModel(in: Array(models.reversed()))?.id
                == ModelID("phonon-31m-en")
        )
        #expect(VoiceOnboardingView.recommendedModel(in: []) == nil)
        #expect(
            VoiceOnboardingView.recommendedModel(
                in: models.filter { $0.stability == .experimental }
            ) == nil
        )
    }

    private func phononModel() throws -> ModelDescriptor {
        try #require(ModelCatalogLoader().bundledCatalog().models.first {
            $0.id.rawValue == "phonon-31m-en"
        })
    }
}
