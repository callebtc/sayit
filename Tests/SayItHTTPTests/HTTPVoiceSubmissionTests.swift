import Foundation
import SayItProtocol
import Testing
@testable import SayItHTTP

@Suite("HTTP voice selection")
struct HTTPVoiceSubmissionTests {
    @Test("Structured voice selection is request scoped")
    func structuredSelection() throws {
        let profileID = UUID()
        let request = HTTPSubmission(
            text: "Read this.",
            voiceSelection: .profile(profileID)
        )

        let submission = try request.serviceSubmission()

        #expect(submission.voice == nil)
        #expect(submission.voiceSelection == .profile(profileID))
        #expect(submission.source == .http)
    }

    @Test("Legacy and structured voice selectors conflict")
    func conflictingSelectors() {
        let request = HTTPSubmission(
            text: "Read this.",
            voice: "af_heart",
            voiceSelection: .automaticStable
        )

        #expect(throws: HTTPAPIError.self) {
            _ = try request.serviceSubmission()
        }
    }

    @Test("Safe profile metadata contains no reference transcript or path")
    func safeProfileMetadataIsRedacted() throws {
        let profile = VoiceProfileSnapshot(
            id: UUID(),
            modelID: "omnivoice",
            displayName: "Silver Lark",
            origin: .recordedClone,
            language: "en-US",
            duration: 8,
            createdAt: .now,
            updatedAt: .now,
            tuning: VoiceTuning()
        )

        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(profile)
            ) as? [String: Any]
        )
        #expect(object["transcript"] == nil)
        #expect(object["path"] == nil)
        #expect(object["reference"] == nil)
    }

    @Test("HTTP catalog advertises model-specific selection modes")
    func modelSelectionModes() {
        let qwen = makeModel(
            voices: [],
            voiceCloning: true,
            voiceDiscovery: true,
            randomVoiceSampling: true
        )
        let modes = HTTPVoiceModelModes(
            model: qwen,
            installedModelIDs: [qwen.id],
            currentSelection: .automaticStable
        )

        #expect(modes.available)
        #expect(
            modes.supportedSelectionModes
                == ["automaticStable", "profile", "randomPerParagraph"]
        )
        #expect(modes.currentSelection == .automaticStable)
    }

    private func makeModel(
        voices: [String],
        voiceCloning: Bool,
        voiceDiscovery: Bool,
        randomVoiceSampling: Bool
    ) -> ModelSnapshot {
        ModelSnapshot(
            id: "test-model",
            displayName: "Test Model",
            family: "Test",
            repository: "local/test",
            revision: String(repeating: "a", count: 40),
            modelType: "test",
            parameterCount: "1",
            quantization: "none",
            languages: ["en"],
            voices: voices,
            defaultVoice: voices.first,
            defaultLanguage: "en",
            downloadByteCount: 0,
            estimatedPeakMemoryBytes: 0,
            hardwareTier: "standard",
            licenseIdentifier: "test",
            licenseURL: URL(string: "https://example.invalid")!,
            commercialUseAllowed: true,
            requiresLicenseAcceptance: false,
            stability: "stable",
            playbackMode: "buffered",
            hasPresetVoices: !voices.isEmpty,
            supportsVoiceDescription: false,
            supportsVoiceCloning: voiceCloning,
            supportsStreaming: false,
            supportsLongForm: true,
            supportsLanguageSelection: true,
            requiresReferenceAudio: false,
            supportsVoiceDiscovery: voiceDiscovery,
            supportsRandomVoiceSampling: randomVoiceSampling,
            testedMLXAudioVersion: "0.1.3",
            testedDate: "2026-07-30",
            isSelectable: true,
            supportsNativeSpeakingPace: false
        )
    }
}
