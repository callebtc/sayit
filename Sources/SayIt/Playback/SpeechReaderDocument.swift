import Foundation

/// Immutable source tokens. Audio metadata and display width never change identities.
struct SpeechReaderDocument: Sendable {
    static let maximumTokenCharacters = 128

    struct Word: Identifiable, Sendable {
        let id: Int
        let text: String
        let sourceRange: Range<Int>
        let newlinesBefore: Int
        let joinsPrevious: Bool
    }

    let sourceText: String
    let tokens: [Word]

    static let empty = SpeechReaderDocument(sourceText: "", tokens: [])

    static func build(_ text: String) throws -> Self {
        var tokens: [Word] = []
        var cursor = text.startIndex
        var offset = 0
        var newlines = 0

        while cursor < text.endIndex {
            if offset.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let character = text[cursor]
            if character.isWhitespace {
                if character == "\n" { newlines += 1 }
                cursor = text.index(after: cursor)
                offset += 1
                continue
            }
            let start = cursor
            let startOffset = offset
            repeat {
                cursor = text.index(after: cursor)
                offset += 1
            } while cursor < text.endIndex
                && !text[cursor].isWhitespace
                && offset - startOffset < maximumTokenCharacters

            let word = Word(
                id: tokens.count,
                text: String(text[start..<cursor]),
                sourceRange: startOffset..<offset,
                newlinesBefore: newlines,
                joinsPrevious: tokens.last?.sourceRange.upperBound == startOffset
            )
            tokens.append(word)
            newlines = 0
            try Task.checkCancellation()
        }
        return Self(sourceText: text, tokens: tokens)
    }

    func wordIndex(atOrAfter offset: Int) -> Int? {
        var lower = 0
        var upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].sourceRange.upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < tokens.count ? lower : nil
    }
}
