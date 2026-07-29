import Foundation
import Testing
@testable import SayItCore

@Suite("Text cleanup")
struct TextCleanerTests {
    @Test("HTML keeps readable structure and removes hidden content")
    func cleansHTML() async throws {
        #if SWIFT_PACKAGE
        let fixtureBundle = Bundle.module
        #else
        let fixtureBundle = Bundle(for: TestBundleToken.self)
        #endif
        let url = try #require(
            fixtureBundle.url(forResource: "article", withExtension: "html")
        )
        let data = try Data(contentsOf: url)
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, html: data)
        )

        #expect(result.text.contains("A calm title"))
        #expect(result.text.contains("First useful point"))
        #expect(!result.text.contains("never speak this"))
        #expect(!result.text.contains("Hidden title"))
        #expect(result.cleanupSummary.sourceFormat == "HTML")
    }

    @Test("Markdown removes front matter, code fences, syntax, and URLs")
    func cleansMarkdown() async throws {
        let markdown = """
        ---
        draft: true
        ---
        # Listen to this

        Visit [the project](https://example.invalid) and read `inline code`.

        ```swift
        let secret = "do not speak code"
        ```

        Final paragraph.
        """

        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, plainText: markdown)
        )

        #expect(result.text.contains("Listen to this"))
        #expect(result.text.contains("the project"))
        #expect(result.text.contains("inline code"))
        #expect(result.text.contains("Final paragraph"))
        #expect(!result.text.contains("example.invalid"))
        #expect(!result.text.contains("do not speak code"))
        #expect(result.cleanupSummary.removedCodeBlocks == 1)
    }

    @Test("Whitespace is normalized without removing paragraph pauses")
    func normalizesWhitespace() async throws {
        let input = "  First   sentence.\r\n\r\n\r\n Second\tparagraph. \u{0000} "
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .service, plainText: input)
        )

        #expect(result.text == "First sentence.\n\nSecond paragraph.")
        #expect(result.title == "First sentence.")
    }

    @Test("Empty and oversized input are rejected")
    func rejectsInvalidLengths() async {
        await #expect(throws: TextIngestionError.noReadableText) {
            try await TextCleaner().ingest(
                TextSourcePayload(source: .clipboard, plainText: " \n ")
            )
        }

        let oversized = String(
            repeating: "a",
            count: TextCleaner.maximumCharacterCount + 1
        )
        await #expect(
            throws: TextIngestionError.textTooLong(
                limit: TextCleaner.maximumCharacterCount
            )
        ) {
            try await TextCleaner().ingest(
                TextSourcePayload(source: .clipboard, plainText: oversized)
            )
        }
    }
}
