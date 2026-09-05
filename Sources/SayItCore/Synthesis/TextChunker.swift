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

    public func chunks(
        for text: String,
        separatesParagraphs: Bool = false
    ) -> [SpeechChunk] {
        chunks(for: text, separatesParagraphs: separatesParagraphs, checkingCancellation: {})
    }

    public func chunks(
        for text: String,
        separatesParagraphs: Bool = false,
        checkingCancellation: () throws -> Void
    ) rethrows -> [SpeechChunk] {
        try checkingCancellation()
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

        for paragraph in try paragraphs(in: text, checkingCancellation: checkingCancellation) {
            try checkingCancellation()
            let sentences = sentences(
                in: text,
                within: paragraph.range,
                sourceOffset: paragraph.sourceOffset
            )
            var isFirstSentence = true

            for sentence in sentences {
                try checkingCancellation()
                if sentence.text.count > hardCharacterLimit {
                    flush()
                    for piece in try splitOversized(sentence, checkingCancellation: checkingCancellation) {
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

                let separator = isFirstSentence ? "\n" : " "
                if let buffer,
                   buffer.text.count + separator.count + sentence.text.count
                    > targetCharacterCount {
                    flush()
                }
                if let current = buffer {
                    buffer = joining(
                        current,
                        sentence,
                        separator: separator
                    )
                } else {
                    buffer = sentence.reidentified(
                        as: 0,
                        startsParagraph: isFirstSentence
                    )
                }
                isFirstSentence = false
            }
            if separatesParagraphs {
                flush()
            }
        }
        flush()
        return output
    }

    public func chunks(
        for text: String,
        separatesParagraphs: Bool = false,
        fitting fits: (String) throws -> Bool
    ) rethrows -> [SpeechChunk] {
        try chunks(
            for: text, separatesParagraphs: separatesParagraphs,
            checkingCancellation: {}, fitting: fits
        )
    }

    public func chunks(
        for text: String,
        separatesParagraphs: Bool = false,
        checkingCancellation: () throws -> Void,
        fitting fits: (String) throws -> Bool
    ) rethrows -> [SpeechChunk] {
        var output: [SpeechChunk] = []

        for chunk in try chunks(
            for: text,
            separatesParagraphs: separatesParagraphs,
            checkingCancellation: checkingCancellation
        ) {
            try checkingCancellation()
            let pieces = try fittingPieces(for: chunk) { candidate in
                try checkingCancellation()
                return try fits(candidate)
            }
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
        in text: String,
        checkingCancellation: () throws -> Void
    ) rethrows -> [(range: Range<String.Index>, sourceOffset: Int)] {
        var output: [(
            range: Range<String.Index>,
            sourceOffset: Int
        )] = []
        var paragraphStart = text.startIndex
        var cursor = text.startIndex
        var characterOffset = 0
        var paragraphOffset = 0

        func appendParagraph(endingAt end: String.Index) {
            guard paragraphStart < end else { return }
            output.append(
                (
                    paragraphStart..<end,
                    paragraphOffset
                )
            )
        }

        while cursor < text.endIndex {
            if characterOffset.isMultiple(of: 1_024) { try checkingCancellation() }
            guard text[cursor] == "\n" else {
                cursor = text.index(after: cursor)
                characterOffset += 1
                continue
            }
            appendParagraph(endingAt: cursor)
            repeat {
                cursor = text.index(after: cursor)
                characterOffset += 1
            } while cursor < text.endIndex && text[cursor] == "\n"
            paragraphStart = cursor
            paragraphOffset = characterOffset
        }
        appendParagraph(endingAt: text.endIndex)
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

    /// Fit one prepared chunk without reprocessing the rest of the document.
    public func fittingPieces(
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

    private func splitOversized(
        _ chunk: SpeechChunk,
        checkingCancellation: () throws -> Void
    ) rethrows -> [SpeechChunk] {
        var output: [SpeechChunk] = []
        var remainder = chunk.text.startIndex..<chunk.text.endIndex
        var remainderOffset = 0

        while let proposedEnd = chunk.text.index(
            remainder.lowerBound,
            offsetBy: hardCharacterLimit,
            limitedBy: remainder.upperBound
        ), proposedEnd < remainder.upperBound {
            try checkingCancellation()
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
                        characterRange: (
                            remainderOffset + chunk.text.distance(
                                from: remainder.lowerBound, to: pieceRange.lowerBound
                            )
                        )..<(remainderOffset + chunk.text.distance(
                            from: remainder.lowerBound, to: pieceRange.upperBound
                        )),
                        startsParagraph: output.isEmpty
                            && chunk.startsParagraph
                    )
                )
            }
            remainderOffset += chunk.text.distance(
                from: remainder.lowerBound, to: breakIndex
            )
            remainder = breakIndex..<remainder.upperBound
            while remainder.lowerBound < remainder.upperBound,
                  chunk.text[remainder.lowerBound].isWhitespace {
                remainder = chunk.text.index(
                    after: remainder.lowerBound
                )..<remainder.upperBound
                remainderOffset += 1
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
                    characterRange: (
                        remainderOffset + chunk.text.distance(
                            from: remainder.lowerBound, to: finalRange.lowerBound
                        )
                    )..<(remainderOffset + chunk.text.distance(
                        from: remainder.lowerBound, to: finalRange.upperBound
                    )),
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
        _ second: SpeechChunk,
        separator: String
    ) -> SpeechChunk {
        precondition(separator.count == 1)
        return SpeechChunk(
            id: first.id,
            text: first.text + separator + second.text,
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
        var offset = text.distance(from: text.startIndex, to: range.lowerBound)
        var best: String.Index?
        var bestDistance = Int.max
        for index in text[range].indices {
            let distance = abs(offset - midpointOffset)
            if predicate(text[index]), distance < bestDistance {
                best = index
                bestDistance = distance
            }
            offset += 1
        }
        return best.map { text.index(after: $0) }
    }
}
