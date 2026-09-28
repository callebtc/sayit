import Foundation
import Testing
@testable import SayItCore

@Suite("Text cleanup regressions")
struct TextCleanupRegressionTests {
    @Test("Whitespace cleanup never guesses spaces inside technical tokens")
    func preservesTechnicalTokens() async throws {
        let text = "file.Name v1.Beta https://example.test/Some.Path?q=Next!Value U.S.A. First.Next!Another?Last"
        let result = try await TextCleaner().ingest(.init(source: .clipboard, plainText: text))
        #expect(result.text == text)
    }

    @Test("Intentional single newlines remain intact")
    func preservesSourceBreaks() async throws {
        let text = "This is interesting, but\nit’s a smaller derivative.\n- First item\n- Second item"
        let result = try await TextCleaner().ingest(.init(source: .clipboard, plainText: text))
        #expect(result.text == "This is interesting, but\nit’s a smaller derivative.\nFirst item\nSecond item")
    }

    @Test("Unordered list markers are silent while item boundaries survive", arguments: [
        "- ", "* ", "+ ", "• ", "  - ", "\t•\t", "•\u{00A0}"
    ])
    func removesUnorderedListMarkers(prefix: String) async throws {
        let input = "Introduction:\n\(prefix)First item\n\(prefix)Second item.\nConclusion."
        let result = try await TextCleaner().ingest(.init(source: .selection, plainText: input))
        #expect(result.text == "Introduction:\nFirst item\nSecond item.\nConclusion.")
        let chunks = TextChunker(targetCharacterCount: 2_000).chunks(for: result.text)
        #expect(chunks.map(\.text) == [result.text])
    }

    @Test("The reported seven-item selection contains no spoken bullet prefixes")
    func cleansSelectedFeatureList() async throws {
        let items = [
            "Selected text → speech through a configurable global shortcut.",
            "Local Qwen3-TTS, alongside other optional models.",
            "In-app model downloads and voice selection.",
            "Menu-bar playback controls, including pause, seeking, and speed.",
            "Native Swift integration, without requiring a Python setup.",
            "Automatic model unloading after an idle period.",
            "Apple Silicon support on macOS 15 or later. Source and documentation"
        ]
        let heading = "Its documented features include:"
        let ending = "It’s MIT-licensed, with no subscription or cloud inference charges. Models download once, then synthesis works offline."
        let input = ([heading] + items.map { "- " + $0 } + [ending]).joined(separator: "\n")
        let result = try await TextCleaner().ingest(.init(source: .selection, plainText: input))
        #expect(result.text == ([heading] + items + [ending]).joined(separator: "\n"))
    }

    @Test("Bullet cleanup preserves numbers, inline punctuation, and literal code")
    func preservesMeaningfulMarkers() async throws {
        let input = """
        - A well-known fact — and x stays x.
          - Nested point with `a * b` and `- flag`.
        1. First step.
        2) Second step.
        -42 is negative; +3 is positive.
        Use x - y and a + b.
        ```text
        - literal code
        ```
        """
        let result = try await TextCleaner(options: .init(stripCodeBlocks: false)).ingest(
            .init(source: .clipboard, plainText: input)
        )
        #expect(result.text == """
        A well-known fact — and x stays x.
        Nested point with a * b and - flag.
        1. First step.
        2) Second step.
        -42 is negative; +3 is positive.
        Use x - y and a + b.
        ```text
        - literal code
        ```
        """)
    }

    @Test("Bullet markers remain when Markdown stripping or all cleanup is disabled", arguments: [
        TextCleaningOptions(stripMarkdown: false), TextCleaningOptions(isEnabled: false)
    ])
    func preservesOptOutBullets(options: TextCleaningOptions) async throws {
        let input = "- First item\n• Second item\n* Third item\n+ Fourth item"
        let result = try await TextCleaner(options: options).ingest(
            .init(source: .selection, plainText: input)
        )
        #expect(result.text == input)
    }

    @Test("Lists without punctuation force chunks while ordinary wrapped lines stay together")
    func listChunksWithoutPunctuation() async throws {
        let result = try await TextCleaner().ingest(.init(
            source: .selection,
            plainText: "An introduction\nwrapped onto another line\n- Milk\n- Bread\n1. Butter\n2. Eggs\nAfter the list"
        ))
        let chunks = TextChunker(targetCharacterCount: 2_000).chunks(
            for: result.text,
            listItemStartOffsets: Set(result.listItemStartOffsets ?? [])
        )
        #expect(chunks.map(\.text) == [
            "An introduction\nwrapped onto another line", "Milk", "Bread",
            "1. Butter", "2. Eggs", "After the list"
        ])
        #expect(chunks.allSatisfy { $0.startsParagraph })
        for chunk in chunks {
            #expect(String(result.text.dropFirst(chunk.sourceRange.lowerBound).prefix(chunk.sourceRange.count)) == chunk.text)
        }
        #expect(chunks.dropFirst().dropLast().map(\.sourceRange.lowerBound) == result.listItemStartOffsets)
    }

    @Test("HTML lists retain pause boundaries through block tags and whitespace", arguments: [true, false])
    func htmlListOffsets(normalizeWhitespace: Bool) async throws {
        let result = try await TextCleaner(options: .init(normalizeWhitespace: normalizeWhitespace)).ingest(.init(
            source: .clipboard,
            html: Data("<ul><li><p>Milk</p></li><li>Bread</li></ul><p>After</p>".utf8)
        ))
        let chunks = TextChunker(targetCharacterCount: 2_000).chunks(
            for: result.text,
            listItemStartOffsets: Set(result.listItemStartOffsets ?? [])
        )
        #expect(chunks.map(\.text) == ["Milk", "Bread", "After"])
        #expect(chunks.prefix(2).map(\.sourceRange.lowerBound) == result.listItemStartOffsets)
        #expect(!result.text.contains("SAYITLIST"))
    }

    @Test("List offsets survive serialization and older records still decode")
    func listOffsetSerialization() async throws {
        let result = try await TextCleaner().ingest(.init(source: .selection, plainText: "- Milk\n- Bread"))
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(CleanedText.self, from: data) == result)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "listItemStartOffsets")
        let decoded = try JSONDecoder().decode(CleanedText.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.text == result.text)
        #expect(decoded.listItemStartOffsets == nil)
    }

    @Test("Standalone inline Markdown is recognized", arguments: [
        ("Only *italic*.", "Only italic."),
        ("Only _italic_ and __bold__.", "Only italic and bold."),
        ("Only ~~deleted~~.", "Only deleted."),
        ("Use `file.Name`.", "Use file.Name."),
        ("Use `**literal**`.", "Use **literal**."),
        ("Use `[label](url)`.", "Use [label](url)."),
        ("Use ``a`b``.", "Use a`b.")
    ])
    func inlineMarkdown(example: (String, String)) async throws {
        let result = try await TextCleaner().ingest(.init(source: .clipboard, plainText: example.0))
        #expect(result.text == example.1)
        #expect(result.cleanupSummary.sourceFormat == "Markdown")
        let unchanged = try await TextCleaner(options: .init(stripMarkdown: false)).ingest(
            .init(source: .clipboard, plainText: example.0)
        )
        #expect(unchanged.text == example.0)
    }

    @Test("Fenced HTML is code rather than an HTML document", arguments: [true, false])
    func removesFencedHTML(stripMarkdown: Bool) async throws {
        let text = "Before.\n```html\n<p>example</p>\n```\nAfter."
        let result = try await TextCleaner(options: .init(stripMarkdown: stripMarkdown)).ingest(
            .init(source: .clipboard, plainText: text)
        )
        #expect(result.text == "Before.\nAfter.")
        #expect(result.cleanupSummary.removedCodeBlocks == 1)
    }

    @Test("Code removal handles longer fences, nested shorter fences, and unfinished copies")
    func fenceLengths() async throws {
        let text = "Before.\n````html\n```\n<p>example</p>\n```\n````\nBetween.\n~~~swift\nunfinished"
        let result = try await TextCleaner().ingest(.init(source: .clipboard, plainText: text))
        #expect(result.text == "Before.\nBetween.")
        #expect(result.cleanupSummary.removedCodeBlocks == 2)
    }

    @Test("Disabling code removal preserves fenced content literally")
    func preservesFencedCode() async throws {
        let text = "Before.\n```html\n<p>**literal**</p>\n```\nAfter."
        let result = try await TextCleaner(options: .init(stripCodeBlocks: false)).ingest(
            .init(source: .clipboard, plainText: text)
        )
        #expect(result.text == text)
        #expect(result.cleanupSummary.removedCodeBlocks == 0)
    }

    @Test("HTML code blocks are removed, inline code is retained, and counts are reported")
    func htmlCode() async throws {
        let html = Data("<p>Before <code>file.Name</code>.</p><pre><code>do_not_read()</code></pre><p>After.</p>".utf8)
        let result = try await TextCleaner().ingest(.init(source: .clipboard, html: html))
        #expect(result.text == "Before file.Name.\nAfter.")
        #expect(result.cleanupSummary.removedCodeBlocks == 1)
        let kept = try await TextCleaner(options: .init(stripCodeBlocks: false)).ingest(
            .init(source: .clipboard, html: html)
        )
        #expect(kept.text == "Before file.Name.\ndo_not_read()\nAfter.")
        #expect(kept.cleanupSummary.removedCodeBlocks == 0)
    }

    @Test("HTML code removal is independent of stripping HTML tags")
    func removesCodeWithoutStrippingHTML() async throws {
        let html = "<p>Before.</p><pre><code>do_not_read()</code></pre><p>After.</p>"
        let cleaner = TextCleaner(options: .init(stripHTML: false))
        for payload in [
            TextSourcePayload(source: .clipboard, html: Data(html.utf8)),
            TextSourcePayload(source: .clipboard, plainText: html)
        ] {
            let result = try await cleaner.ingest(payload)
            #expect(result.text == "<p>Before.</p><br><br><p>After.</p>")
            #expect(result.cleanupSummary.removedCodeBlocks == 1)
        }
    }

    @Test("Escaped delimiters and identifiers stay literal alongside Markdown")
    func literalDelimiters() async throws {
        let text = #"**Title** file_name \*literal\* \_literal\_ unmatched`"#
        let result = try await TextCleaner().ingest(.init(source: .clipboard, plainText: text))
        #expect(result.text == #"Title file_name \*literal\* \_literal\_ unmatched`"#)
    }

    @Test("HTML extraction and importer failure both preserve exact block boundaries", arguments: [true, false])
    func htmlBoundaries(failImporter: Bool) throws {
        let html = Data("<p>First.</p><ul><li>One</li><li>Two</li></ul><table><tr><td>Left</td><td>Right</td></tr></table><p>Last<br>line.</p>".utf8)
        let parser = TextParser()
        let extracted: String
        if failImporter {
            extracted = try parser.cleanHTML(html) { _ in throw TextIngestionError.invalidRepresentation }.text
        } else {
            extracted = try parser.cleanHTML(html).text
        }
        let result = try parser.parse(.init(source: .clipboard, plainText: extracted))
        #expect(result.text == "First.\nOne\nTwo\nLeft Right\nLast\nline.")
    }

    @Test("Cleanup disabled leaves markup untouched")
    func disabledCleanup() async throws {
        let text = "```html\n<p>**literal**</p>\n```"
        let result = try await TextCleaner(options: .init(isEnabled: false)).ingest(
            .init(source: .clipboard, plainText: text)
        )
        #expect(result.text == text)
    }
}
