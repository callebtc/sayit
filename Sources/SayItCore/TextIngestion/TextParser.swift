import AppKit
import Foundation

struct TextParser: Sendable {
    var options = TextCleaningOptions()

    func parse(_ payload: TextSourcePayload) throws -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int,
        normalizedWhitespace: Bool
    ) {
        guard options.isEnabled else {
            return try rawPassthrough(payload)
        }

        let parsed: (text: String, sourceFormat: String, removedCodeBlocks: Int)

        let plainText = payload.plainText.flatMap { text in
            sanitize(text).isEmpty ? nil : text
        }
        // Browser-provided plain text reflects CSS layout more reliably than
        // fragment HTML. A matching copy is raw HTML rather than a fallback.
        let plainTextMirrorsHTML = plainText.map { text in
            payload.html.flatMap(decodeHTMLSource).map {
                sanitize($0) == sanitize(text)
            } ?? false
        } ?? false
        if let plainText,
           (payload.html == nil
               || (options.stripHTML && !plainTextMirrorsHTML)) {
            parsed = cleanPlainText(plainText)
        } else if let html = payload.html {
            if options.stripHTML {
                let cleaned = try cleanHTML(html)
                parsed = (cleaned.text, "HTML", cleaned.removedCodeBlocks)
            } else if let raw = decodeHTMLSource(html) {
                let cleaned = removeHTMLCodeBlocks(from: raw)
                parsed = (cleaned.text, "HTML", cleaned.removedCodeBlocks)
            } else {
                throw TextIngestionError.invalidRepresentation
            }
        } else if let richText = payload.richText {
            parsed = (try cleanRichText(richText), "Rich text", 0)
        } else if let plainText {
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

    private func rawPassthrough(_ payload: TextSourcePayload) throws -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int,
        normalizedWhitespace: Bool
    ) {
        if let plainText = payload.plainText {
            return (
                sanitize(plainText),
                "Plain text",
                0,
                false
            )
        }
        if let html = payload.html,
           let raw = decodeHTMLSource(html) {
            return (sanitize(raw), "HTML", 0, false)
        }
        if let richText = payload.richText {
            return (sanitize(try cleanRichText(richText)), "Rich text", 0, false)
        }
        throw TextIngestionError.noReadableText
    }

    private func sanitize(_ input: String) -> String {
        input
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanPlainText(_ input: String) -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int
    ) {
        let detectionInput = sanitize(input)

        let hasFences = detectionInput.range(
            of: #"(?m)^[ \t]*(`{3,}|~{3,})"#,
            options: .regularExpression
        ) != nil

        // Code examples may contain HTML. Classify their enclosing fences first.
        if !hasFences, options.stripHTML,
           looksLikeHTML(detectionInput),
           let data = detectionInput.data(using: .utf8),
           let html = try? cleanHTML(data) {
            return (html.text, "HTML", html.removedCodeBlocks)
        }

        if !hasFences, !options.stripHTML, looksLikeHTML(detectionInput) {
            let cleaned = removeHTMLCodeBlocks(from: input)
            return (cleaned.text, "HTML", cleaned.removedCodeBlocks)
        }

        if hasFences || looksLikeMarkdown(detectionInput) {
            if options.stripMarkdown {
                let stripped = stripMarkdownBlocks(from: detectionInput)
                let parsed = parseMarkdown(stripped.text)
                return (parsed, "Markdown", stripped.removedCodeBlocks)
            }
            if options.stripCodeBlocks {
                let stripped = removeCodeBlocks(from: detectionInput)
                return (stripped.text, "Markdown", stripped.removedCodeBlocks)
            }
        }

        return (input, "Plain text", 0)
    }

    private func parseMarkdown(_ input: String) -> String {
        var fence: String?
        return input.components(separatedBy: "\n").map { line in
            if let open = fence {
                if closesFence(line, openedBy: open) { fence = nil }
                // Code removal is off: preserve its contents verbatim.
                return line
            }
            if let open = openingFence(in: line) {
                fence = open
                return line
            }
            return cleanMarkdownLine(line)
        }.joined(separator: "\n")
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
        return prefix + cleanMarkdownCodeSpans(working)
    }

    private func cleanMarkdownCodeSpans(_ input: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\\`])(`+)(?!`)(.+?)\1(?!`)"#
        ) else { return cleanMarkdownInline(input) }
        var output = ""
        var cursor = input.startIndex
        for match in expression.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
            guard let range = Range(match.range, in: input),
                  let literal = Range(match.range(at: 2), in: input) else { continue }
            output += cleanMarkdownInline(String(input[cursor..<range.lowerBound]))
            output += input[literal]
            cursor = range.upperBound
        }
        output += cleanMarkdownInline(String(input[cursor...]))
        return output
    }

    private func cleanMarkdownInline(_ input: String) -> String {
        var working = input
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
        working = replacingMatches(in: working, pattern: #"(?<!\\)\*\*([^*]+)(?<!\\)\*\*"#, with: "$1")
        working = replacingMatches(
            in: working,
            pattern: #"(?<![\w\\])__([^_]+)(?<!\\)__(?!\w)"#,
            with: "$1"
        )
        working = replacingMatches(in: working, pattern: #"(?<!\\)\*([^*]+)(?<!\\)\*"#, with: "$1")
        working = replacingMatches(
            in: working,
            pattern: #"(?<![\w\\])_([^_]+)(?<!\\)_(?!\w)"#,
            with: "$1"
        )
        working = replacingMatches(in: working, pattern: #"(?<!\\)~~([^~]+)(?<!\\)~~"#, with: "$1")
        return working
    }

    // The importer is injectable so boundary preservation is tested on failure too.
    func cleanHTML(
        _ data: Data,
        using importer: (Data) throws -> String = TextParser.readHTML
    ) throws -> (text: String, removedCodeBlocks: Int) {
        guard var source = decodeHTMLSource(data) else {
            throw TextIngestionError.invalidRepresentation
        }

        source = removingMatches(
            in: source,
            pattern: #"(?is)<!--.*?-->|<(script|style|head|noscript|template|svg|canvas|iframe|object)\b[^>]*>.*?</\1>"#
        )
        let codeCleanup = removeHTMLCodeBlocks(from: source)
        source = codeCleanup.text
        // Importers can discard <br> inside lists or collapse whitespace. Use a
        // collision-free text marker and restore it after either extraction path.
        var boundary = "SAYITBOUNDARY" + UUID().uuidString
        while source.contains(boundary) { boundary += "X" }
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</?(p|div|main|section|article|header|footer|nav|aside|h[1-6]|blockquote|pre|address|figure|figcaption|details|summary|fieldset|legend|dl|dt|dd|ul|ol|table|caption|form)\b[^>]*>"#,
            with: boundary + boundary
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<(li|tr)\b[^>]*>"#,
            with: ""
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</(li|tr)\s*>"#,
            with: boundary
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<br\b[^>]*>"#,
            with: boundary
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<hr\b[^>]*>"#,
            with: boundary + boundary
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<(td|th)\b[^>]*>"#,
            with: ""
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</(td|th)\s*>"#,
            with: " "
        )

        guard let cleanedData = source.data(using: .utf8) else {
            throw TextIngestionError.invalidRepresentation
        }
        let extracted: String
        do {
            extracted = try importer(cleanedData)
        } catch {
            let withoutTags = replacingMatches(
                in: source,
                pattern: #"(?s)<[^>]+>"#,
                with: ""
            )
            extracted = decodeCommonHTMLEntities(in: withoutTags)
        }
        return (extracted.replacing(boundary, with: "\n"), codeCleanup.removedCodeBlocks)
    }

    private func removeHTMLCodeBlocks(from source: String) -> (text: String, removedCodeBlocks: Int) {
        guard options.stripCodeBlocks,
              let expression = try? NSRegularExpression(pattern: #"(?is)<pre\b[^>]*>.*?</pre\s*>"#) else {
            return (source, 0)
        }
        let range = NSRange(source.startIndex..., in: source)
        let count = expression.numberOfMatches(in: source, range: range)
        let text = expression.stringByReplacingMatches(
            in: source, range: range, withTemplate: "<br><br>"
        )
        return (text, count)
    }

    private static func readHTML(_ data: Data) throws -> String {
        try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ).string
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

    private func decodeHTMLSource(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf32,
            .windowsCP1252,
            .isoLatin1
        ]
        return encodings.lazy.compactMap { encoding in
            String(data: data, encoding: encoding)
        }.first
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
        guard options.stripCodeBlocks else {
            return (working, 0)
        }
        return removeCodeBlocks(from: working)
    }

    private func removeCodeBlocks(from input: String) -> (
        text: String,
        removedCodeBlocks: Int
    ) {
        var fence: String?
        var count = 0
        var lines: [String] = []
        for line in input.components(separatedBy: "\n") {
            if let open = fence {
                if closesFence(line, openedBy: open) {
                    fence = nil
                    lines.append("")
                }
            } else if let open = openingFence(in: line) {
                fence = open
                count += 1
                lines.append("")
            } else {
                lines.append(line)
            }
        }
        return (lines.joined(separator: "\n"), count)
    }

    private func openingFence(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let fence = trimmed.prefix(while: { $0 == first })
        return fence.count >= 3 ? String(fence) : nil
    }

    private func closesFence(_ line: String, openedBy fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first }
    }

    private func normalize(_ input: String) -> String {
        let canonical = input.precomposedStringWithCanonicalMapping
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
            .replacing("\u{2029}", with: "\n\n")
            .replacing("\u{2028}", with: "\n")
            .replacing("\u{0085}", with: "\n")
            .replacing("\u{000C}", with: "\n\n")
            .replacing("\u{000B}", with: "\n")

        var value: String
        if options.stripSpecialCharacters {
            let allowedControls = CharacterSet.newlines.union(.whitespaces)
            let withoutControls = canonical.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || allowedControls.contains(scalar)
            }
            value = String(String.UnicodeScalarView(withoutControls))
                // Common clipboard artifacts that are neither spoken nor visible.
                .replacing("\u{00AD}", with: "")
                .replacing("\u{200B}", with: "")
                .replacing("\u{2060}", with: "")
                .replacing("\u{FEFF}", with: "")
                .replacing("\u{FFFC}", with: " ")
        } else {
            value = canonical
        }
        guard options.normalizeWhitespace else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = replacingMatches(
            in: value,
            pattern: #"[\p{Zs}\t]+"#,
            with: " "
        )
        value = replacingMatches(
            in: value,
            pattern: #"[ \t]*\n[ \t]*"#,
            with: "\n"
        )
        value = replacingMatches(
            in: value,
            pattern: #"\n+"#,
            with: "\n"
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeHTML(_ text: String) -> Bool {
        text.range(
            of: #"<(html|body|p|div|article|section|h[1-6]|ul|ol|li|br|table|pre)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func looksLikeMarkdown(_ text: String) -> Bool {
        text.range(
            of: #"(?m)^(#{1,6}\s|[-*+]\s|>\s|```|~~~)|\[[^\]]+\]\([^)]+\)|\*[^*\n]+\*|(?<!\w)_{1,2}[^_\n]+_{1,2}(?!\w)|~~[^~\n]+~~|`[^`\n]+`"#,
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
