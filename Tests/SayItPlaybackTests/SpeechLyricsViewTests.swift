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

    @Test("Streaming follows a stable passage and never guesses future word times")
    func streamingTimingIsStable() {
        let chunks = [PlaybackTextChunk(textStart: 0, textEnd: 650, audioStart: 0)]
        // Generated duration deliberately is not an input to alignment.
        for _ in [2.0, 10.0, 40.0] {
            #expect(SpeechLyricsTimeline.chunkIndex(at: 1.5, chunks: chunks) == 0)
            #expect(SpeechLyricsTimeline.timing(forOffset: 325, chunks: chunks) == 0)
        }
        #expect(SpeechLyricsTimeline.timing(forOffset: 650, chunks: chunks) == .infinity)
        #expect(SpeechLyricsTimeline.timing(forOffset: -1, chunks: chunks) == .infinity)
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

    @Test("Legacy recordings without anchors do not invent proportional word alignment")
    func noProportionalFallback() {
        #expect(SpeechLyricsTimeline.chunkIndex(at: 90, chunks: []) == nil)
        #expect(SpeechLyricsTimeline.timing(forOffset: 1000, chunks: []) == .infinity)
        let anchors = [
            PlaybackTextChunk(textStart: 0, textEnd: 1000, audioStart: 0, audioEnd: 120),
            PlaybackTextChunk(textStart: 1000, textEnd: 2000, audioStart: 120, audioEnd: 180)
        ]
        #expect(SpeechLyricsTimeline.chunkIndex(at: 90, chunks: anchors) == 0)
        #expect(SpeechLyricsTimeline.timing(forOffset: 1000, chunks: anchors) == 120)
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
