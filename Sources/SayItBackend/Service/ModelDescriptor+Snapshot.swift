import SayItCore
import SayItProtocol

extension ModelDescriptor {
    var serviceSnapshot: ModelSnapshot {
        ModelSnapshot(
            id: id.rawValue,
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
            downloadByteCount: downloadByteCount,
            estimatedPeakMemoryBytes: estimatedPeakMemoryBytes,
            hardwareTier: hardwareTier.rawValue,
            licenseIdentifier: license.identifier,
            licenseURL: license.url,
            commercialUseAllowed: license.commercialUseAllowed,
            requiresLicenseAcceptance: license.requiresAcceptance,
            stability: stability.rawValue,
            playbackMode: playbackMode.rawValue,
            hasPresetVoices: capabilities.presetVoices,
            supportsVoiceDescription: capabilities.voiceDescription,
            supportsVoiceCloning: capabilities.voiceCloning,
            supportsStreaming: capabilities.streaming,
            supportsLongForm: capabilities.longForm,
            supportsLanguageSelection: capabilities.languageSelection,
            requiresReferenceAudio: capabilities.requiresReferenceAudio,
            supportsVoiceDiscovery: capabilities.supportsVoiceDiscovery,
            supportsRandomVoiceSampling:
                capabilities.supportsRandomVoiceSampling,
            voiceCloneRequirements: capabilities.voiceCloneRequirements.map {
                VoiceCloneRequirementsSnapshot(
                    minimumDuration: $0.minimumDuration,
                    recommendedMinimumDuration:
                        $0.recommendedMinimumDuration,
                    recommendedMaximumDuration:
                        $0.recommendedMaximumDuration,
                    maximumDuration: $0.maximumDuration,
                    transcriptRequired: $0.transcriptRequired
                )
            },
            testedMLXAudioVersion: testedMLXAudioVersion,
            testedDate: testedDate,
            isSelectable: isSelectable,
            supportsNativeSpeakingPace: supportsNativeSpeakingPace
        )
    }
}
