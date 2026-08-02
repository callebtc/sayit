import Testing
@testable import SayIt

@Suite("Voice clone recording prompt")
struct VoiceCloneRecordingPromptTests {
    @Test("Transcript models ask for the displayed passage")
    func transcriptPrompt() {
        let prompt = VoiceCloneRecordingPrompt(
            passage: "Read this exact passage.",
            transcriptRequired: true
        )

        #expect(prompt.title == "READ ALOUD")
        #expect(prompt.text == "Read this exact passage.")
        #expect(prompt.transcript == "Read this exact passage.")
        #expect(prompt.idleInstruction.contains("read the passage"))
    }

    @Test("Transcript-free models allow natural speech")
    func transcriptFreePrompt() {
        let prompt = VoiceCloneRecordingPrompt(
            passage: "This passage should not be used.",
            transcriptRequired: false
        )

        #expect(prompt.title == "SPEAK NATURALLY")
        #expect(prompt.text.contains("any topic"))
        #expect(prompt.transcript.isEmpty)
        #expect(!prompt.idleInstruction.contains("passage"))
        #expect(!prompt.activeInstruction.contains("passage"))
    }
}
