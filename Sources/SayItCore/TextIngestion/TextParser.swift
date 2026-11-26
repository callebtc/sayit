import AppKit
import Foundation

struct TextParser: Sendable {
    var options = TextCleaningOptions()

    private static let allowedControlScalars = CharacterSet.newlines.union(.whitespaces)
    private static let controlCharacterScalars = CharacterSet.controlCharacters
    private static let closingPunctuation: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", ")", "]", "\u{00BB}"
    ]
    private static let terminalPunctuation: Set<Character> = [
        ".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"
    ]

    private enum Regex {
        static let fences = compile(#"(?m)^[ \t]*(`{3,}|~{3,})"#)
        static let horizontalRule = compile(#"^(([-*_])\s*){3,}$|^=+$"#)
        static let bullet = compile(#"^[-*+•][\p{Zs}\t]+"#)
        static let numberedList = compile(#"^\d+[.)][\p{Zs}\t]+"#)
        static let heading = compile(#"^#{1,6}\s+"#)
        static let blockquote = compile(#"^>\s?"#)
        static let codeSpan = compile(#"(?<![\\`])(`+)(?!`)(.+?)\1(?!`)"#)
        static let markdownImage = compile(#"!\[([^\]]*)\]\([^)]+\)"#)
        static let markdownLink = compile(#"\[([^\]]+)\]\([^)]+\)"#)
        static let boldAsterisk = compile(#"(?<!\\)\*\*(?!\s)([^\s*\\]|[^\s*][^*]*?[^\s*\\])\*\*"#)
        static let boldUnderscore = compile(#"(?<![\w\\])__(?!\s)([^\s_\\]|[^\s_][^_]*?[^\s_\\])__(?!\w)"#)
        static let italicAsterisk = compile(#"(?<!\\)\*(?!\s)([^\s*\\]|[^\s*][^*]*?[^\s*\\])\*"#)
        static let italicUnderscore = compile(#"(?<![\w\\])_(?!\s)([^\s_\\]|[^\s_][^_]*?[^\s_\\])_(?!\w)"#)
        static let strikethrough = compile(#"(?<!\\)~~(?!\s)([^\s~\\]|[^\s~][^~]*?[^\s~\\])~~"#)
        static let htmlNoise = compile(#"(?is)<!--.*?-->|<(script|style|head|noscript|template|svg|canvas|iframe|object)\b[^>]*>.*?</\1>"#)
        static let htmlBlockTag = compile(#"(?i)</?(p|div|main|section|article|header|footer|nav|aside|h[1-6]|blockquote|pre|address|figure|figcaption|details|summary|fieldset|legend|dl|dt|dd|ul|ol|table|caption|form)\b[^>]*>"#)
        static let htmlLiOpen = compile(#"(?i)<li\b[^>]*>"#)
        static let htmlTrOpen = compile(#"(?i)<tr\b[^>]*>"#)
        static let htmlLiTrClose = compile(#"(?i)</(li|tr)\s*>"#)
        static let htmlBr = compile(#"(?i)<br\b[^>]*>"#)
        static let htmlHr = compile(#"(?i)<hr\b[^>]*>"#)
        static let htmlCellOpen = compile(#"(?i)<(td|th)\b[^>]*>"#)
        static let htmlCellClose = compile(#"(?i)</(td|th)\s*>"#)
        static let htmlTag = compile(#"(?s)<[^>]+>"#)
        static let htmlPre = compile(#"(?is)<pre\b[^>]*>.*?</pre\s*>"#)
        static let htmlHeading = compile(#"(?is)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#)
        static let looksLikeHTML = compile(#"<(html|body|p|div|article|section|h[1-6]|ul|ol|li|br|table|pre)\b"#, options: .caseInsensitive)
        static let looksLikeMarkdown = compile(#"(?m)^([ \t]*(?:[-*+•]|\d+[.)])[\p{Zs}\t]+|#{1,6}\s|>\s|```|~~~)|\[[^\]]+\]\([^)]+\)|(?<!\\)\*\*(?!\s)(?:[^\s*\\\n]|[^\s*\n][^*\n]*?[^\s*\\\n])\*\*|(?<!\\)\*(?!\s)(?:[^\s*\\\n]|[^\s*\n][^*\n]*?[^\s*\\\n])\*|(?<![\w\\])__(?!\s)(?:[^\s_\\\n]|[^\s_\n][^_\n]*?[^\s_\\\n])__(?!\w)|(?<![\w\\])_(?!\s)(?:[^\s_\\\n]|[^\s_\n][^_\n]*?[^\s_\\\n])_(?!\w)|(?<!\\)~~(?!\s)(?:[^\s~\\\n]|[^\s~\n][^~\n]*?[^\s~\\\n])~~|`[^`\n]+`"#)
        static let arrow = compile("→[\u{FE0E}\u{FE0F}]?")
        static let horizontalSpace = compile(#"[\p{Zs}\t]+"#)
        static let newlineSpaces = compile(#"[ \t]*\n[ \t]*"#)
        static let multiNewline = compile(#"\n+"#)
        static let blankLineSeparator = compile(#"(?:\n[ \t]*){2,}"#)

        private static func compile(
            _ pattern: String,
            options: NSRegularExpression.Options = []
        ) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    func parse(_ payload: TextSourcePayload) throws -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int,
        normalizedWhitespace: Bool,
        listItemStartOffsets: [Int],
        paragraphBreakStartOffsets: [Int]
    ) {
        guard options.isEnabled else {
            return try rawPassthrough(payload)
        }

        let listMarker = "SAYITLIST" + UUID().uuidString
        let breakMarker = "SAYITBREAK" + UUID().uuidString
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
            parsed = cleanPlainText(
                plainText,
                listMarker: listMarker,
                breakMarker: breakMarker
            )
        } else if let html = payload.html {
            if options.stripHTML {
                let cleaned = try cleanHTML(
                    html,
                    listMarker: listMarker,
                    breakMarker: breakMarker
                )
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
            parsed = cleanPlainText(
                plainText,
                listMarker: listMarker,
                breakMarker: breakMarker
            )
        } else {
            throw TextIngestionError.noReadableText
        }

        let withBlockBreaks = markUnpunctuatedBlankLineBlocks(
            in: parsed.text,
            listMarker: listMarker,
            breakMarker: breakMarker
        )
        // A block inside a list item or after a heading can put whitespace after
        // its marker. Move markers past whitespace before computing offsets.
        let marked = shiftMarkersPastWhitespace(
            in: withBlockBreaks,
            listMarker: listMarker,
            breakMarker: breakMarker
        )
        let normalized = shiftMarkersPastWhitespace(
            in: normalize(marked),
            listMarker: listMarker,
            breakMarker: breakMarker
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let extracted = extractMarkers(
            from: normalized,
            listMarker: listMarker,
            breakMarker: breakMarker
        )
        let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var unnormalizedPlain = parsed.text
        if unnormalizedPlain.contains(listMarker) {
            unnormalizedPlain = unnormalizedPlain.replacing(listMarker, with: "")
        }
        if unnormalizedPlain.contains(breakMarker) {
            unnormalizedPlain = unnormalizedPlain.replacing(breakMarker, with: "")
        }
        let textCount = text.count
        let listItemStartOffsets: [Int] = extracted.listItemStartOffsets.isEmpty
            ? []
            : Array(Set(extracted.listItemStartOffsets.filter { $0 < textCount })).sorted()
        let paragraphBreakStartOffsets: [Int] = extracted.paragraphBreakStartOffsets.isEmpty
            ? []
            : Array(Set(extracted.paragraphBreakStartOffsets.filter { $0 > 0 && $0 < textCount })).sorted()
        return (
            text: text,
            sourceFormat: parsed.sourceFormat,
            removedCodeBlocks: parsed.removedCodeBlocks,
            normalizedWhitespace: text != unnormalizedPlain,
            listItemStartOffsets: listItemStartOffsets,
            paragraphBreakStartOffsets: paragraphBreakStartOffsets
        )
    }

    private func rawPassthrough(_ payload: TextSourcePayload) throws -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int,
        normalizedWhitespace: Bool,
        listItemStartOffsets: [Int],
        paragraphBreakStartOffsets: [Int]
    ) {
        if let plainText = payload.plainText {
            return (
                sanitize(plainText),
                "Plain text",
                0,
                false,
                [],
                []
            )
        }
        if let html = payload.html,
           let raw = decodeHTMLSource(html) {
            return (sanitize(raw), "HTML", 0, false, [], [])
        }
        if let richText = payload.richText {
            return (sanitize(try cleanRichText(richText)), "Rich text", 0, false, [], [])
        }
        throw TextIngestionError.noReadableText
    }

    private func sanitize(_ input: String) -> String {
        var result = input
        if result.unicodeScalars.contains("\r") {
            result = result
                .replacing("\r\n", with: "\n")
                .replacing("\r", with: "\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanPlainText(
        _ input: String,
        listMarker: String,
        breakMarker: String
    ) -> (
        text: String,
        sourceFormat: String,
        removedCodeBlocks: Int
    ) {
        let detectionInput = sanitize(input)

        let hasFences = (detectionInput.contains("```") || detectionInput.contains("~~~"))
            && hasMatch(Regex.fences, in: detectionInput)

        // Code examples may contain HTML. Classify their enclosing fences first.
        if !hasFences, options.stripHTML,
           looksLikeHTML(detectionInput),
           let data = detectionInput.data(using: .utf8),
           let html = try? cleanHTML(
               data,
               listMarker: listMarker,
               breakMarker: breakMarker
           ) {
            return (html.text, "HTML", html.removedCodeBlocks)
        }

        if !hasFences, !options.stripHTML, looksLikeHTML(detectionInput) {
            let cleaned = removeHTMLCodeBlocks(from: input)
            return (cleaned.text, "HTML", cleaned.removedCodeBlocks)
        }

        if hasFences || looksLikeMarkdown(detectionInput) {
            if options.stripMarkdown {
                let stripped = stripMarkdownBlocks(from: detectionInput)
                let parsed = parseMarkdown(
                    stripped.text,
                    listMarker: listMarker,
                    breakMarker: breakMarker
                )
                return (parsed, "Markdown", stripped.removedCodeBlocks)
            }
            if options.stripCodeBlocks {
                let stripped = removeCodeBlocks(from: detectionInput)
                return (stripped.text, "Markdown", stripped.removedCodeBlocks)
            }
        }

        return (input, "Plain text", 0)
    }

    private func parseMarkdown(
        _ input: String,
        listMarker: String,
        breakMarker: String
    ) -> String {
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
            return cleanMarkdownLine(
                line,
                listMarker: listMarker,
                breakMarker: breakMarker
            )
        }.joined(separator: "\n")
    }

    private func cleanMarkdownLine(
        _ line: String,
        listMarker: String,
        breakMarker: String
    ) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let first = trimmed.first,
           first == "-" || first == "*" || first == "_" || first == "=",
           hasMatch(Regex.horizontalRule, in: trimmed) {
            return ""
        }
        var working = trimmed
        var prefix = ""
        if let bullet = firstMatchRange(Regex.bullet, in: working) {
            // Keep the list boundary as metadata, never as a spoken symbol.
            prefix = listMarker
            working.removeSubrange(bullet)
        } else if working.first?.isASCII == true && working.first?.isNumber == true,
                  let number = firstMatchRange(Regex.numberedList, in: working) {
            prefix = listMarker + String(working[number])
            working.removeSubrange(number)
        }
        var isHeading = false
        if working.first == "#",
           let heading = firstMatchRange(Regex.heading, in: working) {
            isHeading = true
            working.removeSubrange(heading)
        }
        if working.first == ">" {
            working = replacingMatches(in: working, using: Regex.blockquote, with: "")
        }
        let cleaned = cleanMarkdownCodeSpans(working)
        if isHeading, !cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
            return breakMarker + prefix + cleaned + breakMarker
        }
        return prefix + cleaned
    }

    private func cleanMarkdownCodeSpans(_ input: String) -> String {
        guard input.contains("`") else {
            return cleanMarkdownInline(input)
        }
        let matches = Regex.codeSpan.matches(
            in: input,
            range: NSRange(input.startIndex..., in: input)
        )
        guard !matches.isEmpty else {
            return cleanMarkdownInline(input)
        }
        var output = ""
        var cursor = input.startIndex
        for match in matches {
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
        if working.contains("[") && working.contains("(") {
            if working.contains("![") {
                working = replacingMatches(in: working, using: Regex.markdownImage, with: "$1")
            }
            working = replacingMatches(in: working, using: Regex.markdownLink, with: "$1")
        }
        if working.contains("*") {
            if working.contains("**") {
                working = replacingMatches(in: working, using: Regex.boldAsterisk, with: "$1")
            }
            if working.contains("*") {
                working = replacingMatches(in: working, using: Regex.italicAsterisk, with: "$1")
            }
        }
        if working.contains("_") {
            if working.contains("__") {
                working = replacingMatches(in: working, using: Regex.boldUnderscore, with: "$1")
            }
            if working.contains("_") {
                working = replacingMatches(in: working, using: Regex.italicUnderscore, with: "$1")
            }
        }
        if working.contains("~~") {
            working = replacingMatches(in: working, using: Regex.strikethrough, with: "$1")
        }
        return working
    }

    // The importer is injectable so boundary preservation is tested on failure too.
    func cleanHTML(
        _ data: Data,
        listMarker: String = "",
        breakMarker: String = "",
        using importer: (Data) throws -> String = TextParser.readHTML
    ) throws -> (text: String, removedCodeBlocks: Int) {
        guard var source = decodeHTMLSource(data) else {
            throw TextIngestionError.invalidRepresentation
        }

        source = replacingMatches(in: source, using: Regex.htmlNoise, with: "")
        let codeCleanup = removeHTMLCodeBlocks(from: source)
        source = codeCleanup.text
        // Importers can discard <br> inside lists or collapse whitespace. Use a
        // collision-free text marker and restore it after either extraction path.
        var boundary = "SAYITBOUNDARY" + UUID().uuidString
        while source.contains(boundary) { boundary += "X" }
        source = markHTMLHeadings(
            in: source,
            boundary: boundary,
            breakMarker: breakMarker
        )
        source = replacingMatches(in: source, using: Regex.htmlBlockTag, with: boundary + boundary)
        source = replacingMatches(in: source, using: Regex.htmlLiOpen, with: boundary + listMarker)
        source = replacingMatches(in: source, using: Regex.htmlTrOpen, with: "")
        source = replacingMatches(in: source, using: Regex.htmlLiTrClose, with: boundary)
        source = replacingMatches(in: source, using: Regex.htmlBr, with: boundary)
        source = replacingMatches(in: source, using: Regex.htmlHr, with: boundary + boundary)
        source = replacingMatches(in: source, using: Regex.htmlCellOpen, with: "")
        source = replacingMatches(in: source, using: Regex.htmlCellClose, with: " ")

        guard let cleanedData = source.data(using: .utf8) else {
            throw TextIngestionError.invalidRepresentation
        }
        let extracted: String
        do {
            extracted = try importer(cleanedData)
        } catch {
            let withoutTags = replacingMatches(in: source, using: Regex.htmlTag, with: "")
            extracted = decodeCommonHTMLEntities(in: withoutTags)
        }
        return (extracted.replacing(boundary, with: "\n"), codeCleanup.removedCodeBlocks)
    }

    private func removeHTMLCodeBlocks(from source: String) -> (text: String, removedCodeBlocks: Int) {
        guard options.stripCodeBlocks else {
            return (source, 0)
        }
        let range = NSRange(source.startIndex..., in: source)
        let count = Regex.htmlPre.numberOfMatches(in: source, range: range)
        guard count > 0 else { return (source, 0) }
        let text = Regex.htmlPre.stringByReplacingMatches(
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
        var canonical = input.precomposedStringWithCanonicalMapping
        let canonicalScalars = canonical.unicodeScalars
        if canonicalScalars.contains("\r") {
            canonical = canonical
                .replacing("\r\n", with: "\n")
                .replacing("\r", with: "\n")
        }
        if canonical.unicodeScalars.contains("\u{2029}") { canonical = canonical.replacing("\u{2029}", with: "\n\n") }
        if canonical.unicodeScalars.contains("\u{2028}") { canonical = canonical.replacing("\u{2028}", with: "\n") }
        if canonical.unicodeScalars.contains("\u{0085}") { canonical = canonical.replacing("\u{0085}", with: "\n") }
        if canonical.unicodeScalars.contains("\u{000C}") { canonical = canonical.replacing("\u{000C}", with: "\n\n") }
        if canonical.unicodeScalars.contains("\u{000B}") { canonical = canonical.replacing("\u{000B}", with: "\n") }

        var value: String
        if options.stripSpecialCharacters {
            let hasDisallowedControl = canonical.unicodeScalars.contains { scalar in
                Self.controlCharacterScalars.contains(scalar)
                    && !Self.allowedControlScalars.contains(scalar)
            }
            if hasDisallowedControl {
                let withoutControls = canonical.unicodeScalars.filter { scalar in
                    !Self.controlCharacterScalars.contains(scalar)
                        || Self.allowedControlScalars.contains(scalar)
                }
                value = String(String.UnicodeScalarView(withoutControls))
            } else {
                value = canonical
            }
            // Common clipboard artifacts that are neither spoken nor visible.
            if value.unicodeScalars.contains("\u{00AD}") { value = value.replacing("\u{00AD}", with: "") }
            if value.unicodeScalars.contains("\u{200B}") { value = value.replacing("\u{200B}", with: "") }
            if value.unicodeScalars.contains("\u{2060}") { value = value.replacing("\u{2060}", with: "") }
            if value.unicodeScalars.contains("\u{FEFF}") { value = value.replacing("\u{FEFF}", with: "") }
            if value.unicodeScalars.contains("\u{FFFC}") { value = value.replacing("\u{FFFC}", with: " ") }
            // Neural voices can pronounce the arrow as an unrelated sound.
            // Expand this transition explicitly, including text/emoji presentation.
            if value.unicodeScalars.contains("→") {
                value = replacingMatches(in: value, using: Regex.arrow, with: " to ")
            }
        } else {
            value = canonical
        }
        guard options.normalizeWhitespace else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = replacingMatches(in: value, using: Regex.horizontalSpace, with: " ")
        if value.unicodeScalars.contains("\n") {
            value = replacingMatches(in: value, using: Regex.newlineSpaces, with: "\n")
            value = replacingMatches(in: value, using: Regex.multiNewline, with: "\n")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeHTML(_ text: String) -> Bool {
        text.contains("<") && hasMatch(Regex.looksLikeHTML, in: text)
    }

    private func looksLikeMarkdown(_ text: String) -> Bool {
        hasMatch(Regex.looksLikeMarkdown, in: text)
    }

    private func markHTMLHeadings(
        in source: String,
        boundary: String,
        breakMarker: String
    ) -> String {
        guard !breakMarker.isEmpty else {
            return source
        }
        let matches = Regex.htmlHeading.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        guard !matches.isEmpty else { return source }
        var output = ""
        var cursor = source.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: source),
                  let innerRange = Range(match.range(at: 2), in: source) else {
                continue
            }
            output += source[cursor..<fullRange.lowerBound]
            let inner = String(source[innerRange])
            let plainInner = decodeCommonHTMLEntities(
                in: replacingMatches(in: inner, using: Regex.htmlTag, with: "")
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if plainInner.isEmpty {
                output += boundary + boundary
            } else {
                output += boundary + boundary + breakMarker + inner + breakMarker + boundary + boundary
            }
            cursor = fullRange.upperBound
        }
        output += source[cursor...]
        return output
    }

    private func markUnpunctuatedBlankLineBlocks(
        in input: String,
        listMarker: String,
        breakMarker: String
    ) -> String {
        var canonical = input
        if canonical.unicodeScalars.contains("\r") {
            canonical = canonical
                .replacing("\r\n", with: "\n")
                .replacing("\r", with: "\n")
        }
        if canonical.unicodeScalars.contains("\u{2029}") { canonical = canonical.replacing("\u{2029}", with: "\n\n") }
        if canonical.unicodeScalars.contains("\u{000C}") { canonical = canonical.replacing("\u{000C}", with: "\n\n") }
        guard canonical.unicodeScalars.contains("\n") else { return input }
        let matches = Regex.blankLineSeparator.matches(
            in: canonical,
            range: NSRange(canonical.startIndex..., in: canonical)
        )
        guard !matches.isEmpty else { return input }

        var blocks: [String] = []
        blocks.reserveCapacity(matches.count + 1)
        var separators: [String] = []
        separators.reserveCapacity(matches.count)
        var cursor = canonical.startIndex
        for match in matches {
            guard let range = Range(match.range, in: canonical) else { continue }
            blocks.append(String(canonical[cursor..<range.lowerBound]))
            separators.append(String(canonical[range]))
            cursor = range.upperBound
        }
        blocks.append(String(canonical[cursor...]))

        var breakBefore = Set<Int>()
        for (index, block) in blocks.enumerated() {
            if block.contains(listMarker) {
                continue
            }
            let withoutBreak = block.contains(breakMarker)
                ? block.replacing(breakMarker, with: "")
                : block
            let content = withoutBreak.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty,
                  !endsWithTerminalPunctuation(content) else {
                continue
            }
            if index > 0 {
                breakBefore.insert(index)
            }
            if index + 1 < blocks.count {
                breakBefore.insert(index + 1)
            }
        }
        guard !breakBefore.isEmpty else { return input }

        var output = ""
        output.reserveCapacity(canonical.utf8.count + breakBefore.count * breakMarker.utf8.count)
        for (index, block) in blocks.enumerated() {
            if breakBefore.contains(index) {
                output += breakMarker
            }
            output += block
            if index < separators.count {
                output += separators[index]
            }
        }
        return output
    }

    private func endsWithTerminalPunctuation(_ text: String) -> Bool {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            let ch = text[prev]
            if Self.closingPunctuation.contains(ch) || ch.isWhitespace {
                end = prev
            } else {
                return Self.terminalPunctuation.contains(ch)
            }
        }
        return false
    }

    private func shiftMarkersPastWhitespace(
        in input: String,
        listMarker: String,
        breakMarker: String
    ) -> String {
        guard input.contains(listMarker) || input.contains(breakMarker) else {
            return input
        }
        let escapedList = NSRegularExpression.escapedPattern(for: listMarker)
        let escapedBreak = NSRegularExpression.escapedPattern(for: breakMarker)
        guard let expression = try? NSRegularExpression(
            pattern: "((?:\(escapedList)|\(escapedBreak))+)(\\s+)"
        ) else {
            return input
        }
        var current = input
        while true {
            let next = replacingMatches(in: current, using: expression, with: "$2$1")
            if next == current {
                return current
            }
            current = next
        }
    }

    private func extractMarkers(
        from input: String,
        listMarker: String,
        breakMarker: String
    ) -> (
        text: String,
        listItemStartOffsets: [Int],
        paragraphBreakStartOffsets: [Int]
    ) {
        let hasList = input.contains(listMarker)
        let hasBreak = input.contains(breakMarker)
        guard hasList || hasBreak else {
            return (input, [], [])
        }
        var text = ""
        text.reserveCapacity(input.utf8.count)
        var textCount = 0
        var listItemStartOffsets: [Int] = []
        var paragraphBreakStartOffsets: [Int] = []
        var cursor = input.startIndex
        while cursor < input.endIndex {
            let listRange = hasList
                ? input.range(of: listMarker, range: cursor..<input.endIndex)
                : nil
            let breakRange = hasBreak
                ? input.range(of: breakMarker, range: cursor..<input.endIndex)
                : nil
            switch (listRange, breakRange) {
            case (nil, nil):
                let segment = input[cursor...]
                text += segment
                cursor = input.endIndex
            case (let list?, nil):
                let segment = input[cursor..<list.lowerBound]
                text += segment
                textCount += segment.count
                listItemStartOffsets.append(textCount)
                cursor = list.upperBound
            case (nil, let brk?):
                let segment = input[cursor..<brk.lowerBound]
                text += segment
                textCount += segment.count
                paragraphBreakStartOffsets.append(textCount)
                cursor = brk.upperBound
            case (let list?, let brk?):
                if list.lowerBound <= brk.lowerBound {
                    let segment = input[cursor..<list.lowerBound]
                    text += segment
                    textCount += segment.count
                    listItemStartOffsets.append(textCount)
                    cursor = list.upperBound
                } else {
                    let segment = input[cursor..<brk.lowerBound]
                    text += segment
                    textCount += segment.count
                    paragraphBreakStartOffsets.append(textCount)
                    cursor = brk.upperBound
                }
            }
        }
        return (text, listItemStartOffsets, paragraphBreakStartOffsets)
    }

    private func hasMatch(
        _ expression: NSRegularExpression,
        in input: String
    ) -> Bool {
        expression.firstMatch(
            in: input,
            range: NSRange(input.startIndex..., in: input)
        ) != nil
    }

    private func firstMatchRange(
        _ expression: NSRegularExpression,
        in input: String
    ) -> Range<String.Index>? {
        guard let match = expression.firstMatch(
            in: input,
            range: NSRange(input.startIndex..., in: input)
        ) else {
            return nil
        }
        return Range(match.range, in: input)
    }

    private func replacingMatches(
        in input: String,
        using expression: NSRegularExpression,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private func decodeCommonHTMLEntities(in input: String) -> String {
        guard input.contains("&") else { return input }
        return input
            .replacing("&nbsp;", with: " ")
            .replacing("&amp;", with: "&")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
    }
}
