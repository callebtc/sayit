import Foundation
import NaturalLanguage

public struct TextChunker: Sendable {
    public let targetCharacterCount: Int
    public let hardCharacterLimit: Int

    public init(targetCharacterCount: Int = 650, hardCharacterLimit: Int = 1_000) {
        self.targetCharacterCount = targetCharacterCount
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

    private func splitOversized(_ text: String) -> [String] {
        var output: [String] = []
        var remainder = text[...]

        while remainder.count > hardCharacterLimit {
            let proposedEnd = remainder.index(
                remainder.startIndex,
                offsetBy: hardCharacterLimit
            )
            let searchRange = remainder.startIndex..<proposedEnd
            let breakIndex = remainder[searchRange].lastIndex(where: {
                $0.isWhitespace || $0 == "," || $0 == ";"
            }) ?? proposedEnd
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
}
