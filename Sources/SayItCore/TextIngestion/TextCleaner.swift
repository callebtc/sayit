import AppKit
import Foundation
import NaturalLanguage

public actor TextCleaner: TextIngesting {
    public static let confirmationThreshold = 50_000
    public static let maximumCharacterCount = 200_000

    public init() {}

    public func ingest(_ payload: TextSourcePayload) async throws -> CleanedText {
        let result: (text: String, format: String, removedCodeBlocks: Int)

        if let html = payload.html {
            result = (try cleanHTML(html), "HTML", 0)
        } else if let richText = payload.richText {
            result = (try cleanRichText(richText), "Rich text", 0)
        } else if let plainText = payload.plainText {
            result = cleanPlainText(plainText)
        } else {
            throw TextIngestionError.noReadableText
        }

        let normalized = normalize(result.text)
        guard !normalized.isEmpty else {
            throw TextIngestionError.noReadableText
        }
        guard normalized.count <= Self.maximumCharacterCount else {
            throw TextIngestionError.textTooLong(limit: Self.maximumCharacterCount)
        }

        return CleanedText(
            text: normalized,
            title: makeTitle(from: normalized),
            detectedLanguage: detectLanguage(in: normalized),
            cleanupSummary: CleanupSummary(
                sourceFormat: result.format,
                removedCodeBlocks: result.removedCodeBlocks,
                normalizedWhitespace: normalized != result.text
            ),
            requiresLongTextConfirmation: normalized.count > Self.confirmationThreshold
        )
    }

    private func cleanPlainText(_ input: String) -> (
        text: String,
        format: String,
        removedCodeBlocks: Int
    ) {
        if looksLikeHTML(input), let data = input.data(using: .utf8),
           let html = try? cleanHTML(data) {
            return (html, "HTML", 0)
        }

        if looksLikeMarkdown(input) {
            let stripped = stripMarkdownBlocks(from: input)
            let parsed = (try? AttributedString(
                markdown: stripped.text,
                options: .init(interpretedSyntax: .full)
            )).map { String($0.characters) } ?? stripped.text
            return (parsed, "Markdown", stripped.removedCodeBlocks)
        }

        return (input, "Plain text", 0)
    }

    private func cleanHTML(_ data: Data) throws -> String {
        guard var source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else {
            throw TextIngestionError.invalidRepresentation
        }

        source = removingMatches(
            in: source,
            pattern: #"(?is)<!--.*?-->|<(script|style|head|noscript|template)\b[^>]*>.*?</\1>"#
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</?(p|div|section|article|header|footer|h[1-6]|li|tr|blockquote|pre|br)\b[^>]*>"#,
            with: "\n"
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</?(td|th)\b[^>]*>"#,
            with: " "
        )

        guard let cleanedData = source.data(using: .utf8) else {
            throw TextIngestionError.invalidRepresentation
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        do {
            let attributed = try NSAttributedString(
                data: cleanedData,
                options: options,
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            let withoutTags = replacingMatches(
                in: source,
                pattern: #"(?s)<[^>]+>"#,
                with: ""
            )
            return decodeCommonHTMLEntities(in: withoutTags)
        }
    }

    private func cleanRichText(_ data: Data) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        return try NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ).string
    }

    private func stripMarkdownBlocks(from input: String) -> (
        text: String,
        removedCodeBlocks: Int
    ) {
        var working = input
        if working.hasPrefix("---\n"),
           let range = working.range(of: "\n---\n", range: working.index(
               working.startIndex,
               offsetBy: 4
           )..<working.endIndex) {
            working.removeSubrange(working.startIndex..<range.upperBound)
        }

        let expression = try? NSRegularExpression(
            pattern: #"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$"#
        )
        let range = NSRange(working.startIndex..., in: working)
        let count = expression?.numberOfMatches(in: working, range: range) ?? 0
        let withoutBlocks = expression?.stringByReplacingMatches(
            in: working,
            range: range,
            withTemplate: "\n"
        ) ?? working
        return (withoutBlocks, count)
    }

    private func normalize(_ input: String) -> String {
        let canonical = input.precomposedStringWithCanonicalMapping
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")

        let allowedControls = CharacterSet.newlines.union(.whitespaces)
        let withoutControls = canonical.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || allowedControls.contains(scalar)
        }
        var value = String(String.UnicodeScalarView(withoutControls))
        value = replacingMatches(
            in: value,
            pattern: #"[ \t]+"#,
            with: " "
        )
        value = replacingMatches(
            in: value,
            pattern: #"[ \t]*\n[ \t]*"#,
            with: "\n"
        )
        value = replacingMatches(
            in: value,
            pattern: #"\n{3,}"#,
            with: "\n\n"
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeTitle(from text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var title = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            title = String(text[range])
            return false
        }
        if title.isEmpty {
            title = text
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count > 80 else { return title }
        let end = title.index(title.startIndex, offsetBy: 77)
        return String(title[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func detectLanguage(in text: String) -> String? {
        let sample = String(text.prefix(2_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    private func looksLikeHTML(_ text: String) -> Bool {
        text.range(
            of: #"<(html|body|p|div|article|section|h[1-6]|ul|ol|li|br|table)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func looksLikeMarkdown(_ text: String) -> Bool {
        text.range(
            of: #"(?m)^(#{1,6}\s|[-*+]\s|>\s|```|~~~)|\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*"#,
            options: .regularExpression
        ) != nil
    }

    private func removingMatches(in input: String, pattern: String) -> String {
        replacingMatches(in: input, pattern: pattern, with: "")
    }

    private func replacingMatches(
        in input: String,
        pattern: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        return expression.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private func decodeCommonHTMLEntities(in input: String) -> String {
        input
            .replacing("&nbsp;", with: " ")
            .replacing("&amp;", with: "&")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
    }
}
