import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Backend value semantics")
struct BackendPrimitiveTests {
    @Test("Playback failures have stable user-facing descriptions")
    func playbackErrorDescriptions() {
        let cases: [(PlaybackError, String)] = [
            (.emptyAudio, "no playable audio"),
            (.invalidSampleRate, "unsupported sample rate"),
            (.inconsistentSampleRate, "unsupported sample rate"),
            (.invalidSamples, "invalid audio samples"),
            (.audioTooLarge, "too large"),
            (.audioFormatMismatch, "current output device"),
            (.noOutputDevice, "No audio output device"),
            (.couldNotStartEngine, "could not start audio playback"),
            (.unsupportedAudioFile, "could not be read")
        ]

        for (error, expectedFragment) in cases {
            #expect(error.errorDescription?.contains(expectedFragment) == true)
        }
    }

    @Test("Synthesis failures have stable user-facing descriptions")
    func synthesisErrorDescriptions() {
        let cases: [(SynthesisError, String)] = [
            (.modelNotInstalled, "not installed"),
            (.generatedNoAudio, "did not generate"),
            (.invalidReferenceAudio, "reference could not be read"),
            (.speakingPaceUnavailable, "could not apply")
        ]

        for (error, expectedFragment) in cases {
            #expect(error.errorDescription?.contains(expectedFragment) == true)
        }
    }

    @Test("Model manager failures cover all operational boundaries")
    func modelManagerErrorDescriptions() {
        let errors: [ModelManagerError] = [
            .modelNotFound,
            .modelUnavailable,
            .anotherDownloadIsActive,
            .insufficientDiskSpace(required: 1_000_000),
            .invalidDownloadURL,
            .invalidResponse,
            .checksumMismatch(path: "weights.safetensors"),
            .incompleteSnapshot,
            .activeModelCannotBeRemoved
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("String helpers pad only when needed")
    func stringHelpers() {
        #expect("7".leftPadding(toLength: 3, withPad: "0") == "007")
        #expect("123".leftPadding(toLength: 3, withPad: "0") == "123")
        #expect("1234".leftPadding(toLength: 3, withPad: "0") == "1234")
        #expect("".nilIfEmpty == nil)
        #expect("value".nilIfEmpty == "value")
    }

    @Test("Voice fingerprints handle empty, sparse, clipped, and quiet audio")
    func voiceFingerprints() {
        #expect(VoiceFingerprint.make(samples: []).isEmpty)
        #expect(VoiceFingerprint.make(samples: [1], barCount: 0).isEmpty)

        let clipped = VoiceFingerprint.make(
            samples: Array(repeating: 1, count: 56),
            barCount: 28
        )
        #expect(clipped.count == 28)
        #expect(clipped.allSatisfy { $0 == 1 })

        let silence = VoiceFingerprint.make(samples: [0, 0], barCount: 4)
        #expect(silence == [0.08, 0.08, 0.08, 0.08])

        let mixed = VoiceFingerprint.make(
            samples: [0, 0.1, 0.2, 0.3],
            barCount: 2
        )
        #expect(mixed.count == 2)
        #expect(mixed.allSatisfy { (0.08...1).contains($0) })
    }

    @Test("Generated voice names avoid normalized collisions and terminate")
    func voiceNameGeneration() {
        let generator = VoiceNameGenerator()
        let oneName = generator.name(excluding: [])
        #expect(oneName.split(separator: " ").count == 2)

        let adjectives = [
            "Amber", "Bright", "Calm", "Clear", "Cobalt", "Gentle",
            "Golden", "Lunar", "Mellow", "Quiet", "Silver", "Velvet"
        ]
        let nouns = [
            "Brook", "Cedar", "Finch", "Harbor", "Lark", "Meadow",
            "Orchid", "Reed", "Robin", "Sparrow", "Willow", "Wren"
        ]
        var allNames = Set(
            adjectives.flatMap { adjective in
                nouns.map { "\(adjective) \($0)" }
            }
        )
        allNames.insert("quiet wren 2")
        allNames.insert("QUIET WREN 3")
        #expect(generator.name(excluding: allNames) == "Quiet Wren 4")
    }

    @Test("Every speech source maps to its matching ingestion trigger")
    func speechSourceMapping() {
        let cases: [(SpeechJobSource, TriggerSource)] = [
            (.frontend, .frontend),
            (.commandLine, .commandLine),
            (.http, .http),
            (.service, .service),
            (.clipboard, .clipboard),
            (.selection, .selection),
            (.history, .history),
            (.preview, .preview)
        ]
        for (source, expected) in cases {
            #expect(source.triggerSource == expected)
        }
    }

    @Test("Profile records redact private persistence fields in snapshots")
    func profileSnapshotProjection() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000)
        let updated = Date(timeIntervalSince1970: 2_000)
        let record = VoiceProfileRecord(
            schemaVersion: 1,
            id: id,
            modelID: "test-model",
            displayName: "Silver Finch",
            origin: .recordedClone,
            language: "en",
            transcript: "private transcript",
            duration: 4,
            referenceFilename: "reference.wav",
            createdAt: created,
            updatedAt: updated,
            sortOrder: 3,
            tuning: VoiceTuning(preset: .expressive),
            generationSeed: 42
        )

        #expect(record.snapshot.id == id)
        #expect(record.snapshot.displayName == "Silver Finch")
        #expect(record.snapshot.createdAt == created)
        #expect(record.snapshot.updatedAt == updated)
        #expect(record.snapshot.sortOrder == 3)
        #expect(record.snapshot.origin == .recordedClone)
    }
}
