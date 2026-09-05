import Foundation
import Testing
@testable import SayItCore

@Suite("Speech chunking")
struct TextChunkerTests {
    @Test("On-demand model fitting keeps original offsets and only processes the selected chunk")
    func fitsOnePreparedChunk() throws {
        let text = String(repeating: "First sentence has several words.\n", count: 50)
        let chunker = TextChunker(targetCharacterCount: 200, hardCharacterLimit: 250)
        let chunks = chunker.chunks(for: text)
        let selected = try #require(chunks.dropFirst(3).first)
        let pieces = chunker.fittingPieces(for: selected) { $0.count <= 40 }
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.text.count <= 40 })
        #expect(pieces.first?.sourceRange.lowerBound == selected.sourceRange.lowerBound)
        #expect(pieces.last?.sourceRange.upperBound == selected.sourceRange.upperBound)
        let actualWords: [String] = pieces.flatMap { piece in
            piece.text.split(whereSeparator: \.isWhitespace).map { String($0) }
        }
        let expectedWords = selected.text.split(whereSeparator: \.isWhitespace).map { String($0) }
        #expect(actualWords == expectedWords)
        #expect(throws: CancellationError.self) {
            _ = try chunker.fittingPieces(for: selected) { _ in throw CancellationError() }
        }
    }

    @Test("Large Unicode paragraphs and oversized sentences preserve source offsets")
    func longUnicodeSources() {
        for text in [
            String(repeating: "  Café 👋 reads.\n\n", count: 2_000),
            String(repeating: "café 👨‍👩‍👧‍👦 ", count: 4_000)
        ] {
            let chunks = TextChunker().chunks(for: text)
            #expect(chunks.allSatisfy { $0.text.count <= 1_000 })
            let characters = Array(text)
            let sourceWords = chunks.flatMap {
                String(characters[$0.sourceRange]).split(whereSeparator: \.isWhitespace).map(String.init)
            }
            #expect(sourceWords == text.split(whereSeparator: \.isWhitespace).map(String.init))
            #expect(zip(chunks, chunks.dropFirst()).allSatisfy {
                $0.sourceRange.upperBound <= $1.sourceRange.lowerBound
            })
        }
    }

    @Test("Cancellation interrupts scanning and model fitting")
    func cancelsPreprocessing() {
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try TextChunker().chunks(
                for: String(repeating: "word ", count: 100_000),
                checkingCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        }
        #expect(checks == 3)
        var fitted = 0
        #expect(throws: CancellationError.self) {
            _ = try TextChunker().chunks(
                for: String(repeating: "A sentence. ", count: 200),
                checkingCancellation: {
                    if fitted > 0 { throw CancellationError() }
                },
                fitting: { _ in fitted += 1; return false }
            )
        }
        #expect(fitted == 1)
    }

    @Test("Chunks preserve sentence and paragraph boundaries")
    func preservesBoundaries() {
        let text = """
        First sentence. Second sentence is a little longer.

        A new paragraph begins here. It also has another sentence.
        """
        let chunks = TextChunker(targetCharacterCount: 45).chunks(for: text)

        #expect(chunks.count >= 3)
        #expect(chunks.first?.startsParagraph == true)
        #expect(chunks.contains { $0.text.hasPrefix("A new paragraph") && $0.startsParagraph })
        #expect(chunks.map(\.id) == Array(chunks.indices))
        #expect(
            chunks.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
    }

    @Test("Single clean line breaks remain inside an accumulated block")
    func accumulatesParagraphs() throws {
        let text = "First paragraph.\nSecond paragraph."
        let chunks = TextChunker(targetCharacterCount: 2_000).chunks(for: text)
        let chunk = try #require(chunks.first)

        #expect(chunks.count == 1)
        #expect(chunk.text == text)
        #expect(chunk.startsParagraph)
        #expect(chunk.sourceRange == 0..<text.count)
    }

    @Test("Paragraph-specific voices can still force paragraph blocks")
    func separatesParagraphsWhenRequested() {
        let text = "First paragraph.\nSecond paragraph."
        let chunks = TextChunker(targetCharacterCount: 2_000).chunks(
            for: text,
            separatesParagraphs: true
        )

        #expect(chunks.map(\.text) == ["First paragraph.", "Second paragraph."])
        #expect(chunks.allSatisfy { $0.startsParagraph })
    }

    @Test("Configured target accumulates short article paragraphs")
    func accumulatesShortParagraphsToTarget() {
        let paragraphs = (0..<20).map { index in
            "Paragraph \(index) contains enough words to resemble a short article paragraph while remaining far below the configured block target."
        }
        let text = paragraphs.joined(separator: "\n")
        let chunks = TextChunker(
            targetCharacterCount: 1_300,
            hardCharacterLimit: 1_650
        ).chunks(for: text)

        #expect(chunks.count < paragraphs.count)
        #expect(chunks.allSatisfy { $0.text.count <= 1_300 })
        #expect(chunks.dropLast().allSatisfy { $0.text.count > 1_000 })
        #expect(chunks.contains { $0.text.contains("\n") })
        #expect(
            chunks.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
    }

    @Test("Oversized sentences split at readable boundaries")
    func splitsOversizedSentence() {
        let sentence = String(repeating: "readable words, ", count: 40) + "done."
        let chunks = TextChunker(
            targetCharacterCount: 100,
            hardCharacterLimit: 120
        ).chunks(for: sentence)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 120 })
        #expect(chunks.map(\.text).joined(separator: " ").contains("done."))
    }

    @Test("Model-aware fitting subdivides chunks without losing text")
    func respectsModelLimit() {
        let text = """
        A long opening sentence has several natural places where it can split. \
        The next sentence should also remain in the same continuous reading.
        """
        let chunks = TextChunker(
            targetCharacterCount: 200,
            hardCharacterLimit: 240
        ).chunks(for: text) { candidate in
            candidate.count <= 32
        }

        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.text.count <= 32 })
        #expect(chunks.first?.startsParagraph == true)
        #expect(chunks.dropFirst().allSatisfy { !$0.startsParagraph })
        #expect(
            chunks.flatMap { $0.text.split(separator: " ") }
                == text.split(separator: " ")
        )
        #expect(
            chunks.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
        #expect(chunks.map(\.id) == Array(chunks.indices))
    }

    @Test("Chunks retain source ranges when sentence whitespace is normalized")
    func retainsRangesAcrossNormalizedWhitespace() throws {
        let text = """
        Intro sentence.

        Verse line one
        Verse line two

        Outro sentence.
        """
        let chunks = TextChunker(
            targetCharacterCount: 2_000,
            hardCharacterLimit: 2_500
        ).chunks(for: text)

        #expect(chunks.count == 1)
        #expect(
            chunks[0].text
                == "Intro sentence.\nVerse line one\nVerse line two\nOutro sentence."
        )
        #expect(
            sourceText(in: chunks[0].sourceRange, from: text) == text
        )
        #expect(
            chunks.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
    }

    @Test("Long high-target chunking preserves every source word")
    func longHighTargetChunkingPreservesSourceCoverage() {
        let text = (0..<1_000).map { index in
            "Paragraph \(index) begins.\nLine \(index) continues."
        }.joined(separator: "\n\n")
        let chunks = TextChunker(
            targetCharacterCount: 5_000,
            hardCharacterLimit: 5_350
        ).chunks(for: text)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 5_350 })
        #expect(
            chunks.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
        #expect(
            zip(chunks, chunks.dropFirst()).allSatisfy { pair in
                pair.0.sourceRange.upperBound
                    <= pair.1.sourceRange.lowerBound
            }
        )
    }

    @Test("Adaptive subdivision makes progress for unbroken Unicode text")
    func splitsUnbrokenUnicodeText() {
        let chunk = SpeechChunk(
            id: 4,
            text: String(repeating: "界", count: 31),
            startsParagraph: true,
            sourceRange: 0..<31
        )
        let pieces = TextChunker().subchunks(of: chunk)

        #expect(pieces.count == 2)
        #expect(pieces.map(\.text).joined() == chunk.text)
        #expect(pieces.first?.sourceRange.lowerBound == 0)
        #expect(pieces.last?.sourceRange.upperBound == 31)
        #expect(
            pieces[0].sourceRange.upperBound
                == pieces[1].sourceRange.lowerBound
        )
        #expect(pieces[0].startsParagraph)
        #expect(!pieces[1].startsParagraph)
    }

    @Test("Adaptive subdivision preserves normalized source offsets")
    func adaptiveSubdivisionPreservesNormalizedOffsets() throws {
        let text = "Verse line one\tVerse line two"
        let chunk = try #require(
            TextChunker(targetCharacterCount: 100).chunks(for: text).first
        )
        let pieces = TextChunker().subchunks(of: chunk)

        #expect(pieces.count == 2)
        #expect(pieces.first?.sourceRange.lowerBound == 0)
        #expect(pieces.last?.sourceRange.upperBound == text.count)
        #expect(
            pieces.flatMap {
                sourceText(in: $0.sourceRange, from: text)
                    .split(whereSeparator: \.isWhitespace)
            } == text.split(whereSeparator: \.isWhitespace)
        )
    }

    private func sourceText(
        in range: Range<Int>,
        from text: String
    ) -> Substring {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(lower, offsetBy: range.count)
        return text[lower..<upper]
    }
}
