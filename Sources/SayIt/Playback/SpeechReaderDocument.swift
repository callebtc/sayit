import Foundation

/// Immutable display data. Audio metadata never changes these identities or blocks.
struct SpeechReaderDocument: Sendable {
    static let maximumWordsPerBlock = 32
    static let maximumCharactersPerBlock = 512
    static let maximumTokenCharacters = 128

    struct Word: Identifiable, Sendable {
        let id: Int
        let blockID: Int
        let text: String
        let sourceRange: Range<Int>
        let newlinesBefore: Int
        let joinsPrevious: Bool
    }

    struct Block: Identifiable, Sendable {
        let id: Int
        let words: [Word]
    }

    let sourceText: String
    let blocks: [Block]
    let tokens: [Word]

    static let empty = SpeechReaderDocument(sourceText: "", blocks: [], tokens: [])

    static func build(_ text: String) throws -> Self {
        var tokens: [Word] = []
        var blocks: [Block] = []
        var words: [Word] = []
        var blockCharacters = 0
        var cursor = text.startIndex
        var offset = 0
        var newlines = 0

        func flush() {
            guard !words.isEmpty else { return }
            blocks.append(Block(id: blocks.count, words: words))
            words = []
            blockCharacters = 0
        }

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

            let length = offset - startOffset
            if words.count >= maximumWordsPerBlock
                || blockCharacters + length > maximumCharactersPerBlock
                || newlines > 1 {
                flush()
            }
            let word = Word(
                id: tokens.count,
                blockID: blocks.count,
                text: String(text[start..<cursor]),
                sourceRange: startOffset..<offset,
                newlinesBefore: newlines,
                joinsPrevious: tokens.last?.sourceRange.upperBound == startOffset
            )
            words.append(word)
            tokens.append(word)
            blockCharacters += length
            newlines = 0
            try Task.checkCancellation()
        }
        flush()
        return Self(sourceText: text, blocks: blocks, tokens: tokens)
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
