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

    @Test("Browser plain text preserves paragraphs when clipboard HTML loses them")
    func prefersBrowserPlainText() async throws {
        let html = Data(
            "<article><span>First sentence.</span><span>Like this.</span></article>".utf8
        )
        let result = try await TextCleaner().ingest(
            TextSourcePayload(
                source: .clipboard,
                html: html,
                plainText: "First sentence.\n\nLike this."
            )
        )

        #expect(result.text == "First sentence.\n\nLike this.")
        #expect(result.cleanupSummary.sourceFormat == "Plain text")
    }

    @Test("HTML preserves semantic block, list, and table boundaries")
    func preservesHTMLBoundaries() async throws {
        let html = """
        <main>
          <h1>Article title</h1>
          <p>First paragraph.</p>
          <figure><figcaption>A useful caption.</figcaption></figure>
          <ul><li>First item</li><li>Second item</li></ul>
          <table><tr><td>Left cell</td><td>Right cell</td></tr></table>
          <p>Final paragraph.</p>
        </main>
        """
        let result = try await TextCleaner().ingest(
            TextSourcePayload(
                source: .http,
                html: Data(html.utf8)
            )
        )

        #expect(result.text.contains("Article title\n\nFirst paragraph."))
        #expect(result.text.contains("First item\nSecond item"))
        #expect(result.text.contains("Left cell Right cell"))
        #expect(result.text.contains("A useful caption.\n\nFirst item"))
        #expect(result.text.hasSuffix("Final paragraph."))
    }

    @Test("Website whitespace and missing sentence spaces are repaired")
    func repairsWebsiteTextArtifacts() async throws {
        let input = """
        First\u{00A0}sentence.\u{2029}Second soft\u{00AD}hyphen sentence.\u{FFFC}Third sentence!Next one?Final one.\u{2028}Last line.
        """
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(
            result.text
                == "First sentence.\n\nSecond softhyphen sentence. Third sentence! Next one? Final one.\nLast line."
        )
    }

    @Test("Sentence repair leaves URLs, versions, and initials unchanged")
    func preservesPunctuationWithoutSentenceBoundaries() async throws {
        let input = "Visit https://example.test/path?q=value. Version 2.1 and U.S.A. stay intact."
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(result.text == input)
    }

    @Test("HTML inline markup does not split words")
    func preservesWordsAcrossInlineHTML() async throws {
        let html = Data("<p>A read<em>able</em> result.</p>".utf8)
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, html: html)
        )

        #expect(result.text == "A readable result.")
    }

    @Test("Raw HTML is parsed when its plain fallback mirrors the markup")
    func parsesMirroredRawHTML() async throws {
        let source = "<span>Hello <strong>world.</strong></span>"
        let result = try await TextCleaner().ingest(
            TextSourcePayload(
                source: .http,
                html: Data(source.utf8),
                plainText: source
            )
        )

        #expect(result.text == "Hello world.")
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

    @Test("Lists, line breaks, and punctuation survive cleanup")
    func preservesListsLineBreaksAndPunctuation() async throws {
        let input = """
        Groceries:
        - Milk, eggs
        - Bread (sourdough)

        Steps:
        1. Preheat the oven.
        2. Bake for 20 minutes!
        """
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(result.text.contains("- Milk, eggs"))
        #expect(result.text.contains("- Bread (sourdough)"))
        #expect(result.text.contains("1. Preheat the oven.\n2. Bake for 20 minutes!"))
    }

    @Test("Cleanup can be disabled for raw passthrough")
    func rawPassthroughWhenDisabled() async throws {
        let input = "# Title\n\n- Item **one**  \nwith   spaces"
        let result = try await TextCleaner(
            options: .init(isEnabled: false)
        ).ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(result.text == input)
    }

    @Test("Markdown survives when stripping is off while code blocks are removed")
    func keepsMarkdownWhenStrippingOff() async throws {
        let input = "# Title\n\n```\ncode\n```\n\n- Item **one**"
        let result = try await TextCleaner(
            options: .init(stripMarkdown: false)
        ).ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(result.text.contains("# Title"))
        #expect(result.text.contains("**one**"))
        #expect(!result.text.contains("code"))
        #expect(result.cleanupSummary.removedCodeBlocks == 1)
    }

    @Test("Whitespace is preserved when normalization is off")
    func preservesWhitespaceWhenNormalizationOff() async throws {
        let input = "First   sentence.\n\n\n\nSecond    paragraph."
        let result = try await TextCleaner(
            options: .init(normalizeWhitespace: false)
        ).ingest(
            TextSourcePayload(source: .service, plainText: input)
        )

        #expect(result.text == "First   sentence.\n\n\n\nSecond    paragraph.")
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

    @Test("Leading whitespace does not prevent Markdown parsing or title creation")
    func parsesIndentedMarkdownInput() async throws {
        let input = """


              ---
              draft: true
              ---
              # A useful title

              Body text.
              """
        let result = try await TextCleaner().ingest(
            TextSourcePayload(source: .clipboard, plainText: input)
        )

        #expect(result.cleanupSummary.sourceFormat == "Markdown")
        #expect(result.text.hasPrefix("A useful title"))
        #expect(result.title == "A useful title")
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
