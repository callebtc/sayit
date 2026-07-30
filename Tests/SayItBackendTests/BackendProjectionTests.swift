import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Backend protocol projections")
struct BackendProjectionTests {
    @Test("History projections preserve all voice selection modes")
    func historyVoiceSelections() {
        let profileID = UUID()
        let cases: [(VoiceSynthesisMode, String?, UUID?, VoiceSelection?)] = [
            (.standard, "preset", nil, .preset("preset")),
            (.standard, nil, nil, nil),
            (.automaticStable, nil, nil, .automaticStable),
            (.savedProfile, nil, profileID, .profile(profileID)),
            (.savedProfile, nil, nil, nil),
            (.randomPerParagraph, nil, nil, .randomPerParagraph)
        ]

        for (mode, voice, storedProfileID, expected) in cases {
            let item = HistoryItemSnapshot(
                id: UUID(),
                title: "Title",
                cleanedText: "Text",
                createdAt: .now,
                modelID: ModelID("model"),
                voice: voice,
                voiceMode: mode,
                voiceProfileID: storedProfileID,
                voiceProfileName: "Profile",
                language: "en",
                duration: 2,
                audioRelativePath: "audio.m4a",
                state: .completed,
                isPinned: true
            )
            let projected = item.serviceSnapshot
            #expect(projected.voiceSelection == expected)
            #expect(projected.hasAudio)
            #expect(projected.state == SpeechItemState.completed.rawValue)
            #expect(projected.isPinned)
        }
    }

    @Test("Diagnostic and download projections preserve wire values")
    func diagnosticAndDownloadProjections() {
        let event = DiagnosticEvent(
            severity: .warning,
            category: .synthesis,
            code: "synthesis.warning"
        )
        let diagnostic = event.serviceSnapshot
        #expect(diagnostic.id == event.id)
        #expect(diagnostic.severity == DiagnosticSeverity.warning.rawValue)
        #expect(diagnostic.category == DiagnosticCategory.synthesis.rawValue)
        #expect(diagnostic.code == "synthesis.warning")

        let progress = ModelDownloadProgress(
            modelID: ModelID("model"),
            state: .downloading,
            completedBytes: 25,
            totalBytes: 100,
            bytesPerSecond: 8
        )
        let download = progress.serviceSnapshot
        #expect(download.modelID == "model")
        #expect(download.state == ModelInstallationState.downloading.rawValue)
        #expect(download.completedBytes == 25)
        #expect(download.totalBytes == 100)
        #expect(download.bytesPerSecond == 8)
    }

    @Test("Bundled model snapshots expose capability and pace metadata")
    func modelProjection() throws {
        let models = try ModelCatalogLoader().bundledCatalog().models
        let kokoro = try #require(
            models.first { $0.modelType.lowercased().contains("kokoro") }
        )
        let snapshot = kokoro.serviceSnapshot
        #expect(snapshot.id == kokoro.id.rawValue)
        #expect(snapshot.displayName == kokoro.displayName)
        #expect(
            snapshot.downloadByteCount == kokoro.downloadByteCount
        )
        #expect(snapshot.supportsNativeSpeakingPace)
        #expect(snapshot.isSelectable == kokoro.isSelectable)
    }

    @Test("Playback buffering scales only above normal speed")
    @MainActor
    func playbackBufferPreference() {
        #expect(PlaybackController.preferredStartBufferDuration(for: 0.5) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 1) == 1.2)
        #expect(PlaybackController.preferredStartBufferDuration(for: 2) == 2.4)
        #expect(PlaybackController.highQualityTimePitchOverlap == 32)
    }
}
