import Foundation
import SayItProtocol
import Testing
@testable import SayIt

@Suite("Speech lyrics")
struct SpeechLyricsViewTests {
    @Test("Long documents have bounded display blocks before any audio exists")
    func boundedBlocks() throws {
        let text = String(repeating: "one two three four five. ", count: 20_000)
        let document = try SpeechReaderDocument.build(text)
        #expect(document.tokens.count == 100_000)
        #expect(document.blocks.count > 3_000)
        #expect(document.blocks.allSatisfy {
            $0.words.count <= SpeechReaderDocument.maximumWordsPerBlock
                && $0.words.reduce(0, { $0 + $1.text.count })
                    <= SpeechReaderDocument.maximumCharactersPerBlock
        })
        #expect(document.tokens.map(\.id) == Array(0..<100_000))
    }

    @Test("A single enormous word cannot create an unbounded layout item")
    func boundedUnbrokenText() throws {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 10_000)
        let document = try SpeechReaderDocument.build(text)
        #expect(document.tokens.allSatisfy {
            $0.text.count <= SpeechReaderDocument.maximumTokenCharacters
        })
        #expect(document.tokens.map(\.text).joined() == text)
        #expect(document.tokens.last?.sourceRange.upperBound == 10_000)
    }

    @Test("Unicode offsets, repeated words, and paragraph breaks remain exact")
    func unicodeOffsets() throws {
        let text = "  👨‍👩‍👧‍👦 Café\n\nCafé e\u{301} fin  "
        let document = try SpeechReaderDocument.build(text)
        #expect(document.tokens.map(\.text) == ["👨‍👩‍👧‍👦", "Café", "Café", "e\u{301}", "fin"])
        #expect(document.tokens[2].newlinesBefore == 2)
        #expect(document.blocks.count == 2)
        for token in document.tokens {
            let start = text.index(text.startIndex, offsetBy: token.sourceRange.lowerBound)
            let end = text.index(start, offsetBy: token.sourceRange.count)
            #expect(String(text[start..<end]) == token.text)
            #expect(document.wordIndex(atOrAfter: token.sourceRange.lowerBound) == token.id)
        }
        #expect(document.wordIndex(atOrAfter: text.count) == nil)
    }

    @Test("Empty documents and cancellation do not publish partial tokenizations")
    func emptyAndCancelled() async throws {
        #expect(try SpeechReaderDocument.build(" \n ").tokens.isEmpty)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpeechReaderDocument.build(String(repeating: "word ", count: 10_000))
        }
        do {
            _ = try await work.value
            Issue.record("Cancelled tokenization returned a document")
        } catch is CancellationError { }
    }

    @Test("Streaming estimates advance by word without moving backward as PCM arrives")
    func streamingTimingIsStable() throws {
        let document = try SpeechReaderDocument.build("one two three four five six seven eight nine ten")
        let chunks = [PlaybackTextChunk(textStart: 0, textEnd: 47, audioStart: 0)]
        let initial = SpeechLyricsTimeline.wordIndex(
            at: 1.5, document: document, chunks: chunks, generatedDuration: 2
        )
        #expect(initial != nil && initial! > 0)
        for duration in [2.0, 10.0, 40.0] {
            #expect(SpeechLyricsTimeline.wordIndex(
                at: 1.5, document: document, chunks: chunks, generatedDuration: duration
            ) == initial)
        }
        #expect(SpeechLyricsTimeline.timing(forOffset: 15, chunks: chunks) == 1)
        #expect(SpeechLyricsTimeline.timing(forOffset: 47, chunks: chunks) == .infinity)
        #expect(SpeechLyricsTimeline.timing(forOffset: -1, chunks: chunks) == .infinity)
    }

    @Test("Known audio ends provide local word times and re-anchor every chunk")
    func approximateWordTiming() throws {
        let document = try SpeechReaderDocument.build("one two three four")
        let chunks = [
            PlaybackTextChunk(textStart: 0, textEnd: 7, audioStart: 0, audioEnd: 2),
            PlaybackTextChunk(textStart: 8, textEnd: 18, audioStart: 3, audioEnd: 8)
        ]
        for (elapsed, expected) in [(0.0, 0), (1.5, 1), (3.0, 2), (6.1, 3), (0.2, 0)] {
            #expect(SpeechLyricsTimeline.wordIndex(
                at: elapsed, document: document, chunks: chunks, generatedDuration: 10
            ) == expected)
        }
        for elapsed in [2.0, 2.5, 8, 10, -1, .nan, .infinity] {
            #expect(SpeechLyricsTimeline.wordIndex(
                at: elapsed, document: document, chunks: chunks, generatedDuration: 10
            ) == nil)
        }
        #expect(SpeechLyricsTimeline.timing(forOffset: 14, chunks: chunks) == 6)
    }

    @Test("Unfinished estimates use preceding speech rate and settle on finalized timing")
    func finalizationAndRate() throws {
        let document = try SpeechReaderDocument.build("one two three four")
        let first = PlaybackTextChunk(textStart: 0, textEnd: 7, audioStart: 0, audioEnd: 1)
        let streaming = [first, PlaybackTextChunk(textStart: 8, textEnd: 18, audioStart: 2)]
        #expect(abs(SpeechLyricsTimeline.timing(forOffset: 14, chunks: streaming) - (2 + 6.0 / 7)) < 0.0001)
        let finished = [first, PlaybackTextChunk(textStart: 8, textEnd: 18, audioStart: 2, audioEnd: 7)]
        #expect(SpeechLyricsTimeline.timing(forOffset: 14, chunks: finished) == 5)
        #expect(SpeechLyricsTimeline.wordIndex(at: 4, document: document, chunks: finished, generatedDuration: 8) == 2)
        #expect(SpeechLyricsTimeline.wordIndex(at: 5, document: document, chunks: finished, generatedDuration: 8) == 3)
    }

    @Test("Unicode, whitespace gaps, and chunk boundaries inside tokens stay in their source range")
    func wordBoundaryGaps() throws {
        let document = try SpeechReaderDocument.build("👋 café   café fin")
        let chunks = [
            PlaybackTextChunk(textStart: 0, textEnd: 6, audioStart: 0, audioEnd: 3),
            PlaybackTextChunk(textStart: 9, textEnd: 17, audioStart: 4, audioEnd: 8)
        ]
        #expect(SpeechLyricsTimeline.wordIndex(at: 2, document: document, chunks: chunks, generatedDuration: 9) == 1)
        #expect(SpeechLyricsTimeline.wordIndex(at: 4, document: document, chunks: chunks, generatedDuration: 9) == 2)
        let partial = [PlaybackTextChunk(textStart: 3, textEnd: 5, audioStart: 0, audioEnd: 1)]
        #expect(SpeechLyricsTimeline.wordIndex(at: 0, document: document, chunks: partial, generatedDuration: 2) == 1)
        let empty = [PlaybackTextChunk(textStart: 7, textEnd: 8, audioStart: 0, audioEnd: 1)]
        #expect(SpeechLyricsTimeline.wordIndex(at: 0, document: document, chunks: empty, generatedDuration: 2) == nil)
    }

    @Test("Silence, seeking backward, and completed passage ends respect audio boundaries")
    func audioBoundaries() {
        let chunks = [
            PlaybackTextChunk(textStart: 0, textEnd: 20, audioStart: 0, audioEnd: 2),
            PlaybackTextChunk(textStart: 22, textEnd: 40, audioStart: 3, audioEnd: 6)
        ]
        #expect(SpeechLyricsTimeline.chunkIndex(at: 2.5, chunks: chunks) == nil)
        #expect(SpeechLyricsTimeline.chunkIndex(at: 3, chunks: chunks) == 1)
        #expect(SpeechLyricsTimeline.chunkIndex(at: 1, chunks: chunks) == 0)
        #expect(SpeechLyricsTimeline.chunkIndex(at: 6, chunks: chunks) == nil)
        #expect(SpeechLyricsTimeline.chunkIndex(at: -.infinity, chunks: chunks) == nil)
        #expect(SpeechLyricsTimeline.chunkIndex(at: .nan, chunks: chunks) == nil)
        #expect(SpeechLyricsTimeline.timing(forOffset: 21, chunks: chunks) == .infinity)
    }

    @Test("Legacy recordings retain approximate word following and seeking")
    func proportionalFallback() throws {
        let document = try SpeechReaderDocument.build("one two three four")
        #expect(SpeechLyricsTimeline.wordIndex(at: 14, document: document, chunks: [], generatedDuration: 18) == 3)
        #expect(SpeechLyricsTimeline.legacyTiming(forOffset: 14, textEnd: 18, duration: 18) == 14)
        #expect(SpeechLyricsTimeline.legacyTiming(forOffset: 14, textEnd: 0, duration: 18) == .infinity)
        #expect(SpeechLyricsTimeline.wordIndex(at: 0, document: document, chunks: [], generatedDuration: .nan) == nil)
        #expect(SpeechLyricsTimeline.wordIndex(at: 0, document: .empty, chunks: [], generatedDuration: 10) == nil)
    }

    @Test("A word near the viewport edges scrolls into the comfort band without oscillation")
    func scrollComfortBand() {
        #expect(SpeechReaderScroll.targetOffset(wordFrame: CGRect(x: 0, y: 45, width: 30, height: 18), viewportHeight: 150, contentOffset: 100) == nil)
        let bottom = CGRect(x: 0, y: 125, width: 30, height: 18)
        let target = SpeechReaderScroll.targetOffset(wordFrame: bottom, viewportHeight: 150, contentOffset: 100)
        #expect(target == 171)
        let settled = bottom.offsetBy(dx: 0, dy: -71)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: settled, viewportHeight: 150, contentOffset: 171) == nil)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: CGRect(x: 0, y: 10, width: 30, height: 18), viewportHeight: 150, contentOffset: 100) == 56)
    }

    @Test("Follow coordinates clamp at the start and reject unavailable geometry")
    func scrollBounds() {
        let frame = CGRect(x: 0, y: 10, width: 30, height: 18)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: frame, viewportHeight: 150, contentOffset: 0) == nil)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: frame, viewportHeight: 0, contentOffset: 100) == nil)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: frame, viewportHeight: 150, contentOffset: .nan) == nil)
        #expect(SpeechReaderScroll.targetOffset(wordFrame: .zero, viewportHeight: 150, contentOffset: 100) == nil)
    }

    @Test("Long recordings re-anchor near their end and support distant backward seeks")
    func longRecordingSeeks() throws {
        let phrase = "one two three four five. "
        let stride = phrase.count
        let document = try SpeechReaderDocument.build(String(repeating: phrase, count: 20_000))
        let chunks = (0..<20_000).map {
            PlaybackTextChunk(textStart: $0 * stride, textEnd: $0 * stride + stride - 1,
                              audioStart: Double($0) * 8, audioEnd: Double($0) * 8 + 6)
        }
        for index in [19_999, 1, 10_000, 0] {
            #expect(SpeechLyricsTimeline.wordIndex(
                at: Double(index) * 8, document: document,
                chunks: chunks, generatedDuration: 160_000
            ) == index * 5)
            #expect(SpeechLyricsTimeline.wordIndex(
                at: Double(index) * 8 + 5.9, document: document,
                chunks: chunks, generatedDuration: 160_000
            ) == index * 5 + 4)
            #expect(SpeechLyricsTimeline.wordIndex(
                at: Double(index) * 8 + 7, document: document,
                chunks: chunks, generatedDuration: 160_000
            ) == nil)
        }
    }

    @Test("Active boundary lookup is logarithmic for long recordings")
    func activeWordBinarySearch() {
        var lookupCount = 0
        let index = SpeechLyricsTimeline.activeWordIndex(
            at: 5_432.15, tokenCount: 100_000
        ) { candidate in
            lookupCount += 1
            return Double(candidate) * 0.1
        }
        #expect(index == 54_321)
        #expect(lookupCount <= 17)
    }
}
