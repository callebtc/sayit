import AppKit
import Foundation

struct TextParser: Sendable {
    func parse(_ payload: TextSourcePayload) throws -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int,
        normalizedWhitespace: Bool
    ) {
        let parsed: (text: String, sourceFormat: String, removedCodeBlocks: Int)

        if let html = payload.html {
            parsed = (try cleanHTML(html), "HTML", 0)
        } else if let richText = payload.richText {
            parsed = (try cleanRichText(richText), "Rich text", 0)
        } else if let plainText = payload.plainText {
            parsed = cleanPlainText(plainText)
        } else {
            throw TextIngestionError.noReadableText
        }

        let normalized = normalize(parsed.text)
        return (
            text: normalized,
            sourceFormat: parsed.sourceFormat,
            removedCodeBlocks: parsed.removedCodeBlocks,
            normalizedWhitespace: normalized != parsed.text
        )
    }

    private func cleanPlainText(_ input: String) -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int
    ) {
        let detectionInput = input
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeHTML(detectionInput),
           let data = detectionInput.data(using: .utf8),
           let html = try? cleanHTML(data) {
            return (html, "HTML", 0)
        }

        if looksLikeMarkdown(detectionInput) {
            let stripped = stripMarkdownBlocks(from: detectionInput)
            let parsed = parseMarkdown(stripped.text)
            return (parsed, "Markdown", stripped.removedCodeBlocks)
        }

        return (input, "Plain text", 0)
    }

    private func parseMarkdown(_ input: String) -> String {
        input
            .components(separatedBy: "\n")
            .map(cleanMarkdownLine)
            .joined(separator: "\n")
    }

    private func cleanMarkdownLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.range(
            of: #"^(([-*_])\s*){3,}$|^=+$"#,
            options: .regularExpression
        ) != nil {
            return ""
        }
        var working = trimmed
        var prefix = ""
        if let bullet = working.range(
            of: #"^([-*+•]|\d+[.)])\s+"#,
            options: .regularExpression
        ) {
            prefix = String(working[bullet])
            working.removeSubrange(bullet)
        }
        working = replacingMatches(in: working, pattern: #"^#{1,6}\s+"#, with: "")
        working = replacingMatches(in: working, pattern: #"^>\s?"#, with: "")
        working = replacingMatches(
            in: working,
            pattern: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1"
        )
        working = replacingMatches(
            in: working,
            pattern: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1"
        )
        working = replacingMatches(in: working, pattern: #"`([^`]*)`"#, with: "$1")
        working = replacingMatches(in: working, pattern: #"\*\*([^*]+)\*\*"#, with: "$1")
        working = replacingMatches(
            in: working,
            pattern: #"(?<!\w)__([^_]+)__(?!\w)"#,
            with: "$1"
        )
        working = replacingMatches(in: working, pattern: #"\*([^*]+)\*"#, with: "$1")
        working = replacingMatches(
            in: working,
            pattern: #"(?<!\w)_([^_]+)_(?!\w)"#,
            with: "$1"
        )
        working = replacingMatches(in: working, pattern: #"~~([^~]+)~~"#, with: "$1")
        return prefix + working
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
