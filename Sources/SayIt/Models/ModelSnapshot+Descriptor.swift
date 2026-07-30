import SayItCore
import SayItProtocol

extension ModelSnapshot {
    var descriptor: ModelDescriptor {
        ModelDescriptor(
            id: ModelID(id),
            displayName: displayName,
            family: family,
            repository: repository,
            revision: revision,
            modelType: modelType,
            parameterCount: parameterCount,
            quantization: quantization,
            languages: languages,
            voices: voices,
            defaultVoice: defaultVoice,
            defaultLanguage: defaultLanguage,
            capabilities: ModelCapabilities(
                presetVoices: hasPresetVoices,
                voiceDescription: supportsVoiceDescription,
                voiceCloning: supportsVoiceCloning,
                streaming: supportsStreaming,
                longForm: supportsLongForm,
                languageSelection: supportsLanguageSelection,
                requiresReferenceAudio: requiresReferenceAudio,
                voiceDiscovery: supportsVoiceDiscovery,
                randomVoiceSampling: supportsRandomVoiceSampling,
                voiceCloneRequirements: voiceCloneRequirements.map {
                    VoiceCloneRequirements(
                        minimumDuration: $0.minimumDuration,
                        recommendedMinimumDuration:
                            $0.recommendedMinimumDuration,
                        recommendedMaximumDuration:
                            $0.recommendedMaximumDuration,
                        maximumDuration: $0.maximumDuration,
                        transcriptRequired: $0.transcriptRequired
                    )
                }
            ),
            playbackMode: PlaybackMode(rawValue: playbackMode)
                ?? .progressive,
            files: [],
            estimatedDiskBytes: downloadByteCount,
            estimatedPeakMemoryBytes: estimatedPeakMemoryBytes,
            hardwareTier: HardwareTier(rawValue: hardwareTier) ?? .mid,
            license: ModelLicense(
                identifier: licenseIdentifier,
                url: licenseURL,
                commercialUseAllowed: commercialUseAllowed,
                requiresAcceptance: requiresLicenseAcceptance
            ),
            stability: ModelStability(rawValue: stability)
                ?? .experimental,
            testedMLXAudioVersion: testedMLXAudioVersion,
            testedDate: testedDate
        )
    }
}
