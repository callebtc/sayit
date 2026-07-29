import Testing
@testable import SayItCore

@Suite("Speech title generation")
struct SpeechTitleGeneratorTests {
    private let generator = SpeechTitleGenerator()

    @Test("Leading whitespace and decorative characters are ignored")
    func ignoresDecorativePrefix() {
        let title = generator.title(
            from: "\n \t ### *** \n\n “A useful recording title.” More text."
        )

        #expect(title == "A useful recording title.”")
    }

    @Test("Content without readable title characters gets a fallback")
    func fallsBackForDecorativeContent() {
        #expect(
            generator.title(from: " \n *** ~~ 🎧")
                == SpeechTitleGenerator.fallbackTitle
        )
    }

    @Test("Long titles stay within the display limit")
    func truncatesLongTitles() {
        let title = generator.title(
            from: String(repeating: "word ", count: 30)
        )

        #expect(title.count <= 80)
        #expect(title.hasSuffix("…"))
    }
}
