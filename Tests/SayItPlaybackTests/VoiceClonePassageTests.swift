import Testing
@testable import SayIt

@Suite("Voice clone passage")
struct VoiceClonePassageTests {
    private static let languages: [String?] = [
        nil, "en", "de", "fr", "es", "zh", "ja", "ko", "ru", "pt", "it"
    ]

    @Test("Longer targets extend the shorter passages", arguments: languages)
    func tiersExtendEachOther(language: String?) {
        let short = VoiceClonePassage.text(language: language, targetDuration: 10)
        let medium = VoiceClonePassage.text(language: language, targetDuration: 12)
        let long = VoiceClonePassage.text(
            language: language,
            targetDuration: VoiceClonePassage.longTargetDuration
        )

        #expect(medium.hasPrefix(short))
        #expect(medium.count > short.count)
        #expect(long.hasPrefix(medium))
        #expect(long.count > medium.count)
    }

    @Test("Only the long passage asks a question", arguments: languages)
    func longPassageAddsQuestion(language: String?) {
        let medium = VoiceClonePassage.text(language: language, targetDuration: 19)
        let long = VoiceClonePassage.text(language: language, targetDuration: 30)

        #expect(!medium.contains { "?？".contains($0) })
        #expect(long.contains { "?？".contains($0) })
    }

    @Test("Regional language tags use their base language passage")
    func regionalLanguageTags() {
        #expect(
            VoiceClonePassage.text(language: "pt-BR", targetDuration: 30)
                == VoiceClonePassage.text(language: "pt", targetDuration: 30)
        )
    }
}
