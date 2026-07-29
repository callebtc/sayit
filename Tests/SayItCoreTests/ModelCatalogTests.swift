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

    @Test("Reference-only models cannot be selected")
    func gatesReferenceAudioModels() throws {
        let catalog = try ModelCatalogLoader().bundledCatalog()
        let gated = catalog.models.filter {
            $0.capabilities.requiresReferenceAudio
        }

        #expect(gated.count == 3)
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
}
