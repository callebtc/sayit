import SayItProtocol

extension HistoryItemSnapshot {
    var serviceSnapshot: HistorySnapshot {
        HistorySnapshot(
            id: id,
            title: title,
            cleanedText: cleanedText,
            createdAt: createdAt,
            modelID: modelID.rawValue,
            voice: voice,
            voiceSelection: serviceVoiceSelection,
            voiceProfileName: voiceProfileName,
            language: language,
            duration: duration,
            state: state.rawValue,
            isPinned: isPinned,
            hasAudio: audioRelativePath != nil
        )
    }

    private var serviceVoiceSelection: VoiceSelection? {
        switch voiceMode {
        case .automaticStable:
            .automaticStable
        case .savedProfile:
            voiceProfileID.map(VoiceSelection.profile)
        case .randomPerParagraph:
            .randomPerParagraph
        case .standard:
            voice.map(VoiceSelection.preset)
        }
    }
}
