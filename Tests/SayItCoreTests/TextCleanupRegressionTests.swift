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
        #expect(result.text == text)
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
