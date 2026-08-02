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
                parsed = (try cleanHTML(html), "HTML", 0)
            } else if let raw = decodeHTMLSource(html) {
                parsed = (raw, "HTML", 0)
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

        if options.stripHTML,
           looksLikeHTML(detectionInput),
           let data = detectionInput.data(using: .utf8),
           let html = try? cleanHTML(data) {
            return (html, "HTML", 0)
        }

        if looksLikeMarkdown(detectionInput) {
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
        guard var source = decodeHTMLSource(data) else {
            throw TextIngestionError.invalidRepresentation
        }

        source = removingMatches(
            in: source,
            pattern: #"(?is)<!--.*?-->|<(script|style|head|noscript|template|svg|canvas|iframe|object)\b[^>]*>.*?</\1>"#
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</?(p|div|main|section|article|header|footer|nav|aside|h[1-6]|blockquote|pre|address|figure|figcaption|details|summary|fieldset|legend|dl|dt|dd|ul|ol|table|caption|form)\b[^>]*>"#,
            with: "<br><br>"
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<(li|tr)\b[^>]*>"#,
            with: ""
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)</(li|tr)\s*>"#,
            with: "<br>"
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<br\b[^>]*>"#,
            with: "<br>"
        )
        source = replacingMatches(
            in: source,
            pattern: #"(?i)<hr\b[^>]*>"#,
            with: "<br><br>"
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
        let expression = try? NSRegularExpression(
            pattern: #"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$"#
        )
        let range = NSRange(input.startIndex..., in: input)
        let count = expression?.numberOfMatches(in: input, range: range) ?? 0
        let withoutBlocks = expression?.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: "\n"
        ) ?? input
        return (withoutBlocks, count)
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
        value = replacingMatches(
            in: value,
            pattern: #"([\p{Ll}\p{Nd}]\.[\"'’”)\]]*)(?=\p{Lu})"#,
            with: "$1 "
        )
        value = replacingMatches(
            in: value,
            pattern: #"([!?…][\"'’”)\]]*)(?=\p{Lu})"#,
            with: "$1 "
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
