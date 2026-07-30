import Foundation
import Testing
@testable import SayIt

@Suite("Speech lyrics")
struct SpeechLyricsViewTests {
    @Test("Full-text word ranges map to the start of later blocks")
    func mapsLaterBlockRangesLocally() throws {
        let text = """
        👨‍👩‍👧‍👦 Café opens with several words.

        Second paragraph starts here and continues.
        """
        let blockRange = try #require(
            text.range(of: "Second paragraph starts here and continues.")
        )
        let wordRange = try #require(text.range(of: "Second"))
        let attributed = AttributedString(String(text[blockRange]))
        let localRange = try #require(
            SpeechLyricsView.attributedRange(
                for: wordRange,
                within: blockRange,
                sourceText: text,
                attributedText: attributed
            )
        )

        #expect(String(attributed.characters[localRange]) == "Second")
        #expect(localRange.lowerBound == attributed.startIndex)
    }
}
