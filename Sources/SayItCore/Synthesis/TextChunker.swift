import Foundation
import NaturalLanguage

public struct TextChunker: Sendable {
    public let targetCharacterCount: Int
    public let hardCharacterLimit: Int

    public init(targetCharacterCount: Int = 650, hardCharacterLimit: Int = 1_000) {
        let hardCharacterLimit = max(hardCharacterLimit, 1)
        self.targetCharacterCount = min(
            max(targetCharacterCount, 1),
            hardCharacterLimit
        )
        self.hardCharacterLimit = hardCharacterLimit
    }

    public func chunks(for text: String) -> [SpeechChunk] {
        var output: [SpeechChunk] = []
        var buffer: SpeechChunk?

        func flush() {
            guard let chunk = buffer else { return }
            output.append(
                chunk.reidentified(
                    as: output.count,
                    startsParagraph: chunk.startsParagraph
                )
            )
            buffer = nil
        }

        for paragraph in paragraphs(in: text) {
            let sentences = sentences(
                in: text,
                within: paragraph.range,
                sourceOffset: paragraph.sourceOffset
            )
            var isFirstSentence = true

            for sentence in sentences {
                if sentence.text.count > hardCharacterLimit {
                    flush()
                    for piece in splitOversized(sentence) {
                        output.append(
                            piece.reidentified(
                                as: output.count,
                                startsParagraph: isFirstSentence
                            )
                        )
                        isFirstSentence = false
                    }
                    continue
                }

                if let buffer,
                   buffer.text.count + 1 + sentence.text.count
                    > targetCharacterCount {
                    flush()
                }
                if let current = buffer {
                    buffer = joining(current, sentence)
                } else {
                    buffer = sentence.reidentified(
                        as: 0,
                        startsParagraph: isFirstSentence
                    )
                }
                isFirstSentence = false
            }
            flush()
        }
        return output
    }

    public func chunks(
        for text: String,
        fitting fits: (String) throws -> Bool
    ) rethrows -> [SpeechChunk] {
        var output: [SpeechChunk] = []

        for chunk in chunks(for: text) {
            let pieces = try fittingPieces(for: chunk, fits: fits)
            for (index, piece) in pieces.enumerated() {
                output.append(
                    piece.reidentified(
                        as: output.count,
                        startsParagraph: index == 0 && chunk.startsParagraph
                    )
                )
            }
        }

        return output
    }

    public func subchunks(of chunk: SpeechChunk) -> [SpeechChunk] {
        let pieces = splitNearMiddle(chunk.text)
        guard pieces.count > 1 else { return [chunk] }

        return pieces.enumerated().map { index, textRange in
            chunk.slice(
                id: index,
                textRange: textRange,
                startsParagraph: index == 0 && chunk.startsParagraph
            )
        }
    }

    private func paragraphs(
        in text: String
    ) -> [(range: Range<String.Index>, sourceOffset: Int)] {
        var output: [(
            range: Range<String.Index>,
            sourceOffset: Int
        )] = []
        var cursor = text.startIndex
        var sourceOffset = 0
        while cursor < text.endIndex,
              let separator = text.range(
                of: "\n\n",
                range: cursor..<text.endIndex
              ) {
            let range = cursor..<separator.lowerBound
            output.append((range, sourceOffset))
            sourceOffset += text.distance(
                from: cursor,
                to: separator.upperBound
            )
            cursor = separator.upperBound
        }
        output.append((cursor..<text.endIndex, sourceOffset))
        return output
    }

    private func sentences(
        in source: String,
        within sourceRange: Range<String.Index>,
        sourceOffset: Int
    ) -> [SpeechChunk] {
        let text = String(source[sourceRange])
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var output: [SpeechChunk] = []
        var indexCursor = text.startIndex
        var offsetCursor = sourceOffset
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let trimmed = trimmedRange(in: text, within: range) {
                let lowerOffset = offsetCursor + text.distance(
                    from: indexCursor,
                    to: trimmed.lowerBound
                )
                let upperOffset = lowerOffset + text.distance(
                    from: trimmed.lowerBound,
                    to: trimmed.upperBound
                )
                output.append(
                    SpeechChunk(
                        id: output.count,
                        text: String(text[trimmed]),
                        startsParagraph: output.isEmpty,
                        sourceRange: lowerOffset..<upperOffset
                    )
                )
                indexCursor = trimmed.upperBound
                offsetCursor = upperOffset
            }
            return true
        }
        guard output.isEmpty,
              let trimmed = trimmedRange(
                in: text,
                within: text.startIndex..<text.endIndex
              ) else {
            return output
        }
        let lowerOffset = sourceOffset + text.distance(
            from: text.startIndex,
            to: trimmed.lowerBound
        )
        let upperOffset = sourceOffset + text.distance(
            from: text.startIndex,
            to: trimmed.upperBound
        )
        return [
            SpeechChunk(
                id: 0,
                text: String(text[trimmed]),
                startsParagraph: true,
                sourceRange: lowerOffset..<upperOffset
            )
        ]
    }

    private func fittingPieces(
        for chunk: SpeechChunk,
        fits: (String) throws -> Bool
    ) rethrows -> [SpeechChunk] {
        var output: [SpeechChunk] = []
        var pending = [chunk]

        while let candidate = pending.popLast() {
            if try fits(candidate.text) {
                output.append(candidate)
                continue
            }

            let pieces = subchunks(of: candidate)
            guard pieces.count > 1 else {
                output.append(candidate)
                continue
            }
            pending.append(contentsOf: pieces.reversed())
        }

        return output
    }

    private func splitOversized(_ chunk: SpeechChunk) -> [SpeechChunk] {
        var output: [SpeechChunk] = []
        var remainder = chunk.text.startIndex..<chunk.text.endIndex

        while chunk.text.distance(
            from: remainder.lowerBound,
            to: remainder.upperBound
        ) > hardCharacterLimit {
            let proposedEnd = chunk.text.index(
                remainder.lowerBound,
                offsetBy: hardCharacterLimit
            )
            let searchRange = remainder.lowerBound..<proposedEnd
            let boundaryIndex = chunk.text[searchRange].lastIndex(where: {
                $0.isWhitespace || $0 == "," || $0 == ";"
            })
            let breakIndex = boundaryIndex.map {
                chunk.text.index(after: $0)
            } ?? proposedEnd
            if let pieceRange = trimmedRange(
                in: chunk.text,
                within: remainder.lowerBound..<breakIndex
            ) {
                output.append(
                    chunk.slice(
                        id: output.count,
                        textRange: pieceRange,
                        startsParagraph: output.isEmpty
                            && chunk.startsParagraph
                    )
                )
            }
            remainder = breakIndex..<remainder.upperBound
            while remainder.lowerBound < remainder.upperBound,
                  chunk.text[remainder.lowerBound].isWhitespace {
                remainder = chunk.text.index(
                    after: remainder.lowerBound
                )..<remainder.upperBound
            }
        }

        if let finalRange = trimmedRange(
            in: chunk.text,
            within: remainder
        ) {
            output.append(
                chunk.slice(
                    id: output.count,
                    textRange: finalRange,
                    startsParagraph: output.isEmpty
                        && chunk.startsParagraph
                )
            )
        }
        return output
    }

    private func splitNearMiddle(
        _ text: String
    ) -> [Range<String.Index>] {
        guard text.count > 1 else {
            return [text.startIndex..<text.endIndex]
        }

        let characterCount = text.count
        let midpointOffset = characterCount / 2
        let lowerOffset = max(characterCount / 5, 1)
        let upperOffset = min(characterCount - characterCount / 5, characterCount - 1)
        let lowerBound = text.index(text.startIndex, offsetBy: lowerOffset)
        let upperBound = text.index(text.startIndex, offsetBy: upperOffset)

        let strongBoundaries = ".!?。！？\n"
        let softBoundaries = ",;:—–，、；："
        let splitIndex =
            nearestBoundary(
                in: text,
                range: lowerBound..<upperBound,
                midpointOffset: midpointOffset,
                matching: { strongBoundaries.contains($0) }
            )
            ?? nearestBoundary(
                in: text,
                range: lowerBound..<upperBound,
                midpointOffset: midpointOffset,
                matching: { softBoundaries.contains($0) }
            )
            ?? nearestBoundary(
                in: text,
                range: lowerBound..<upperBound,
                midpointOffset: midpointOffset,
                matching: \.isWhitespace
            )
            ?? text.index(text.startIndex, offsetBy: midpointOffset)

        guard let left = trimmedRange(
            in: text,
            within: text.startIndex..<splitIndex
        ),
        let right = trimmedRange(
            in: text,
            within: splitIndex..<text.endIndex
        ) else {
            return [text.startIndex..<text.endIndex]
        }
        return [left, right]
    }

    private func joining(
        _ first: SpeechChunk,
        _ second: SpeechChunk
    ) -> SpeechChunk {
        SpeechChunk(
            id: first.id,
            text: first.text + " " + second.text,
            startsParagraph: first.startsParagraph,
            sourceBoundaryOffsets: first.sourceBoundaryOffsets
                + [second.sourceRange.lowerBound]
                + Array(second.sourceBoundaryOffsets.dropFirst())
        )
    }

    private func trimmedRange(
        in text: String,
        within range: Range<String.Index>
    ) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }
        while lower < upper {
            let candidate = text.index(before: upper)
            guard text[candidate].isWhitespace else { break }
            upper = candidate
        }
        return lower < upper ? lower..<upper : nil
    }

    private func nearestBoundary(
        in text: String,
        range: Range<String.Index>,
        midpointOffset: Int,
        matching predicate: (Character) -> Bool
    ) -> String.Index? {
        text[range].indices
            .filter { predicate(text[$0]) }
            .min {
                abs(text.distance(from: text.startIndex, to: $0) - midpointOffset)
                    < abs(text.distance(from: text.startIndex, to: $1) - midpointOffset)
            }
            .map { text.index(after: $0) }
    }
}
