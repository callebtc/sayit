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
            duration: duration,
            state: state.rawValue,
            isPinned: isPinned,
            hasAudio: audioRelativePath != nil
        )
    }
}
