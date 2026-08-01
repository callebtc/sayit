struct VoiceCloneRecordingPrompt: Equatable, Sendable {
    let title: String
    let text: String
    let accessibilityLabel: String
    let idleInstruction: String
    let activeInstruction: String
    let transcript: String

    init(passage: String, transcriptRequired: Bool) {
        if transcriptRequired {
            title = "READ ALOUD"
            text = passage
            accessibilityLabel = "Passage to record"
            idleInstruction = "Press the button and read the passage aloud."
            activeInstruction = "Recording — read the passage aloud, then stop."
            transcript = passage
        } else {
            title = "SPEAK NATURALLY"
            text = "Speak naturally about any topic in a clear, steady voice. Use one speaker and avoid background noise."
            accessibilityLabel = "Recording guidance"
            idleInstruction = "Press the button and speak naturally."
            activeInstruction = "Recording — speak naturally, then stop."
            transcript = ""
        }
    }
}
