import Foundation

struct VoiceCloneRecordingPrompt: Equatable, Sendable {
    let title: String
    let text: String
    let accessibilityLabel: String
    let idleInstruction: String
    let activeInstruction: String
    let transcript: String

    init(passage: String, transcriptRequired: Bool) {
        if transcriptRequired {
            title = String(localized: "READ ALOUD")
            text = passage
            accessibilityLabel = String(localized: "Passage to record")
            idleInstruction = String(localized: "Press the button and read the passage aloud.")
            activeInstruction = String(localized: "Recording — read the passage aloud, then stop.")
            transcript = passage
        } else {
            title = String(localized: "SPEAK NATURALLY")
            text = String(localized: "Speak naturally about any topic in a clear, steady voice. Use one speaker and avoid background noise.")
            accessibilityLabel = String(localized: "Recording guidance")
            idleInstruction = String(localized: "Press the button and speak naturally.")
            activeInstruction = String(localized: "Recording — speak naturally, then stop.")
            transcript = ""
        }
    }
}
