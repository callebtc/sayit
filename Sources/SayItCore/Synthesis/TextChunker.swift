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
        let paragraphs = text.components(separatedBy: "\n\n")
        var output: [SpeechChunk] = []
        var buffer = ""
        var bufferStartsParagraph = true

        func flush() {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            output.append(
                SpeechChunk(
                    id: output.count,
                    text: value,
                    startsParagraph: bufferStartsParagraph
                )
            )
            buffer = ""
        }

        for paragraph in paragraphs {
            let sentences = sentences(in: paragraph)
            var isFirstSentence = true

            for sentence in sentences {
                if sentence.count > hardCharacterLimit {
                    flush()
                    for piece in splitOversized(sentence) {
                        output.append(
                            SpeechChunk(
                                id: output.count,
                                text: piece,
                                startsParagraph: isFirstSentence
                            )
                        )
                        isFirstSentence = false
                    }
                    continue
                }

                let separator = buffer.isEmpty ? "" : " "
                if !buffer.isEmpty,
                   buffer.count + separator.count + sentence.count > targetCharacterCount {
                    flush()
                    bufferStartsParagraph = isFirstSentence
                } else if buffer.isEmpty {
                    bufferStartsParagraph = isFirstSentence
                }
                buffer += (buffer.isEmpty ? "" : " ") + sentence
                isFirstSentence = false
            }
            flush()
        }
        flush()
        return output
    }

    public func chunks(
        for text: String,
        fitting fits: (String) throws -> Bool
    ) rethrows -> [SpeechChunk] {
        var output: [SpeechChunk] = []

        for chunk in chunks(for: text) {
            let pieces = try fittingPieces(for: chunk.text, fits: fits)
            for (index, piece) in pieces.enumerated() {
                output.append(
                    SpeechChunk(
                        id: output.count,
                        text: piece,
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

        return pieces.enumerated().map { index, text in
            SpeechChunk(
                id: index,
                text: text,
                startsParagraph: index == 0 && chunk.startsParagraph
            )
        }
    }

    private func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var output: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                output.append(sentence)
            }
            return true
        }
        if output.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return output
    }

    private func fittingPieces(
        for text: String,
        fits: (String) throws -> Bool
    ) rethrows -> [String] {
        var output: [String] = []
        var pending = [text]

        while let candidate = pending.popLast() {
            if try fits(candidate) {
                output.append(candidate)
                continue
            }

            let pieces = splitNearMiddle(candidate)
            guard pieces.count > 1 else {
                output.append(candidate)
                continue
            }
            pending.append(contentsOf: pieces.reversed())
        }

        return output
    }

    private func splitOversized(_ text: String) -> [String] {
        var output: [String] = []
        var remainder = text[...]

        while remainder.count > hardCharacterLimit {
            let proposedEnd = remainder.index(
                remainder.startIndex,
                offsetBy: hardCharacterLimit
            )
            let searchRange = remainder.startIndex..<proposedEnd
            let boundaryIndex = remainder[searchRange].lastIndex(where: {
                $0.isWhitespace || $0 == "," || $0 == ";"
            })
            let breakIndex = boundaryIndex.map {
                remainder.index(after: $0)
            } ?? proposedEnd
            let piece = remainder[..<breakIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                output.append(piece)
            }
            remainder = remainder[breakIndex...]
                .drop(while: \.isWhitespace)
        }

        let final = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            output.append(final)
        }
        return output
    }

    private func splitNearMiddle(_ text: String) -> [String] {
        guard text.count > 1 else { return [text] }

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

        let left = text[..<splitIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = text[splitIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return [text] }
        return [left, right]
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
