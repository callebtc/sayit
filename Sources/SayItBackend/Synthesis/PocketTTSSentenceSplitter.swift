import Foundation
import MLXAudioCore
import MLXAudioTTS

/// Sentence splitter for Pocket TTS / Gradium Phonon models.
///
/// `mlx-audio-swift`'s `PocketTTSTextUtils.splitIntoBestSentences` calls
/// `tokenizer.encode(".!...?")` without stripping the leading SentencePiece
/// metaspace token (`"▁"`), causing every standalone `"▁"` word boundary to
/// be treated as a sentence ending and splitting sentences mid-phrase at the
/// 50-token limit. This splits only on true sentence endings (`.`, `!`, `?`,
/// `…`), drops metaspace/byte-fallback tokens from the punctuation set, skips
/// inner punctuation and titles, keeps closing quotes/brackets attached, and
/// packs multiple short sentences up to `defaultMaxTokens` without splitting
/// individual sentences at commas.
enum PocketTTSSentenceSplitter {
    /// Target token budget for packing multiple short sentences into one chunk.
    static let defaultMaxTokens = 50

    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let weakPunctuation: Set<Character> = [",", ";", ":", "-", "\u{2013}", "\u{2014}"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "\u{00BB}"]
    private static let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "[", "\u{00AB}"]
    private static let titles: Set<String> = [
        "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Rev.", "vs.", "e.g.", "i.e."
    ]

    static func prepareTextPrompt(_ text: String) throws -> (text: String, framesAfterEosGuess: Int) {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else {
            throw NSError(
                domain: "PocketTTSSentenceSplitter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Text prompt cannot be empty"]
            )
        }
        working = working
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2026}", with: "...")
        while working.contains("  ") {
            working = working.replacingOccurrences(of: "  ", with: " ")
        }
        working = working.trimmingCharacters(in: .whitespaces)
        guard !working.isEmpty else {
            throw NSError(
                domain: "PocketTTSSentenceSplitter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Text prompt cannot be empty"]
            )
        }

        let wordCount = working.split(separator: " ").count
        let framesAfterEosGuess = wordCount <= 4 ? 3 : 1

        if let firstContentIndex = working.firstIndex(where: { !openers.contains($0) }) {
            let character = working[firstContentIndex]
            if !character.isUppercase {
                let nextIndex = working.index(after: firstContentIndex)
                working.replaceSubrange(
                    firstContentIndex..<nextIndex,
                    with: character.uppercased()
                )
            }
        }

        working = ensureTerminalPunctuation(working)
        return (working, framesAfterEosGuess)
    }

    static func split(
        _ text: String,
        tokenizer: PocketTTSSentencePieceTokenizer,
        maxTokens: Int = defaultMaxTokens
    ) throws -> [String] {
        try split(
            text,
            tokenizer: tokenizer.tokenizer,
            maxTokens: maxTokens
        )
    }

    static func split(
        _ text: String,
        tokenizerJSONData: Data,
        maxTokens: Int = defaultMaxTokens
    ) throws -> [String] {
        let tokenizer = try SentencePieceTokenizer(tokenizerJSONData: tokenizerJSONData)
        return try split(
            text,
            tokenizer: tokenizer,
            maxTokens: maxTokens
        )
    }

    static func split(
        _ text: String,
        sentencePieceModelData: Data,
        maxTokens: Int = defaultMaxTokens
    ) throws -> [String] {
        let tokenizer = try SentencePieceTokenizer(sentencePieceModelData: sentencePieceModelData)
        return try split(
            text,
            tokenizer: tokenizer,
            maxTokens: maxTokens
        )
    }

    static func split(
        _ text: String,
        tokenizer: SentencePieceTokenizer,
        maxTokens: Int = defaultMaxTokens
    ) throws -> [String] {
        let tokenLimit = max(maxTokens, 1)
        let (prepared, _) = try prepareTextPrompt(text)
        let cleaned = prepared.trimmingCharacters(in: .whitespaces)

        let tokens = tokenizer.encodeWithByteFallback(cleaned)
        guard !tokens.isEmpty else { return [cleaned] }

        let endTokens = punctuationTokenIDs(for: ".!...?", tokenizer: tokenizer)
        let sentenceBoundaries = findBoundaryIndices(
            in: tokens,
            boundaryTokens: endTokens,
            tokenizer: tokenizer
        )
        let sentenceSegments = segments(
            from: tokens,
            boundaries: sentenceBoundaries,
            tokenizer: tokenizer
        )

        let chunks = packSegments(sentenceSegments, tokenLimit: tokenLimit).map(\.text)
        return chunks.isEmpty ? [cleaned] : chunks
    }

    private static func packSegments(
        _ segments: [(count: Int, text: String)],
        tokenLimit: Int
    ) -> [(count: Int, text: String)] {
        var chunks: [(count: Int, text: String)] = []
        var current = ""
        var currentCount = 0
        for (count, segmentText) in segments {
            let trimmed = segmentText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if current.isEmpty {
                current = trimmed
                currentCount = count
                continue
            }
            if currentCount + count > tokenLimit {
                chunks.append((currentCount, current))
                current = trimmed
                currentCount = count
            } else {
                current += " " + trimmed
                currentCount += count
            }
        }
        if !current.isEmpty {
            chunks.append((currentCount, current))
        }
        return chunks
    }

    static func punctuationTokenIDs(
        for characters: String,
        tokenizerJSONData: Data
    ) throws -> Set<Int> {
        let tokenizer = try SentencePieceTokenizer(tokenizerJSONData: tokenizerJSONData)
        return punctuationTokenIDs(for: characters, tokenizer: tokenizer)
    }

    static func punctuationTokenIDs(
        for characters: String,
        tokenizer: SentencePieceTokenizer
    ) -> Set<Int> {
        let metaspaceID = tokenizer.tokenID(for: "▁")
        return Set(
            tokenizer.encodeWithByteFallback(characters).filter { id in
                guard id != metaspaceID,
                      let piece = tokenizer.token(for: id) else {
                    return false
                }
                return !isByteFallbackPiece(piece)
            }
        )
    }

    private static func isByteFallbackPiece(_ piece: String) -> Bool {
        piece.hasPrefix("<0x") && piece.hasSuffix(">") && piece.count == 6
    }

    private static func findBoundaryIndices(
        in tokens: [Int],
        boundaryTokens: Set<Int>,
        tokenizer: SentencePieceTokenizer
    ) -> [Int] {
        guard !boundaryTokens.isEmpty else { return [0, tokens.count] }
        var indices: [Int] = [0]
        var previousWasBoundary = false
        for (idx, token) in tokens.enumerated() {
            if boundaryTokens.contains(token) {
                previousWasBoundary = true
            } else {
                if previousWasBoundary {
                    if !isInnerPunctuation(tokens, start: idx, tokenizer: tokenizer) {
                        let start = skipClosers(tokens, from: idx, tokenizer: tokenizer)
                        if start < tokens.count && start > (indices.last ?? 0) {
                            indices.append(start)
                        }
                    }
                    previousWasBoundary = false
                }
            }
        }
        if indices.last != tokens.count {
            indices.append(tokens.count)
        }
        return indices
    }

    private static func segments(
        from tokens: [Int],
        boundaries: [Int],
        tokenizer: SentencePieceTokenizer
    ) -> [(count: Int, text: String)] {
        guard boundaries.count >= 2 else { return [] }
        var output: [(count: Int, text: String)] = []
        output.reserveCapacity(boundaries.count - 1)
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard start < end else { continue }
            let slice = Array(tokens[start..<end])
            let decoded = tokenizer.decode(slice)
            output.append((end - start, decoded))
        }
        return output
    }

    private static func isInnerPunctuation(
        _ tokens: [Int],
        start: Int,
        tokenizer: SentencePieceTokenizer
    ) -> Bool {
        guard start > 0, start < tokens.count else { return false }
        let after = Array(tokenizer.decode([tokens[start - 1], tokens[start]]))
        if after.count >= 2, after[1].isLetter || after[1].isNumber {
            return true
        }
        let windowStart = max(0, start - 6)
        let words = tokenizer.decode(Array(tokens[windowStart..<start]))
            .split(whereSeparator: \.isWhitespace)
        guard let last = words.last else { return false }
        return titles.contains(String(last)) && (words.count > 1 || windowStart == 0)
    }

    private static func skipClosers(
        _ tokens: [Int],
        from start: Int,
        tokenizer: SentencePieceTokenizer
    ) -> Int {
        var cursor = start
        while cursor < tokens.count {
            let decoded = tokenizer.decode([tokens[cursor]])
            guard !decoded.isEmpty,
                  decoded.allSatisfy({ closers.contains($0) }) else {
                break
            }
            // Only attach closers that follow immediately without a leading space.
            if let piece = tokenizer.token(for: tokens[cursor]),
               piece.hasPrefix("▁") {
                break
            }
            cursor += 1
        }
        return cursor
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        var coreEnd = text.endIndex
        while coreEnd > text.startIndex {
            let prev = text.index(before: coreEnd)
            let ch = text[prev]
            if closers.contains(ch) || ch == " " {
                coreEnd = prev
            } else {
                break
            }
        }
        let core = text[..<coreEnd]
        let trailingClosers = text[coreEnd...].trimmingCharacters(in: .whitespaces)
        guard let lastCore = core.last else { return text }
        if terminalPunctuation.contains(lastCore) {
            return text
        }
        if weakPunctuation.contains(lastCore) {
            var trimmedEnd = core.endIndex
            while trimmedEnd > core.startIndex {
                let prev = core.index(before: trimmedEnd)
                let ch = core[prev]
                if weakPunctuation.contains(ch) || ch == " " {
                    trimmedEnd = prev
                } else {
                    break
                }
            }
            return String(core[..<trimmedEnd]) + "." + trailingClosers
        }
        return text + "."
    }
}
