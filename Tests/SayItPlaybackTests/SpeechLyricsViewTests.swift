import Foundation
import SayItProtocol
import Testing
@testable import SayIt

@Suite("Speech lyrics")
struct SpeechLyricsViewTests {
    @Test("Block ranges split unicode text at chunk boundaries")
    func splitsBlocksWithUnicode() throws {
        let text = """
        👨‍👩‍👧‍👦 Café opens with several words.

        Second paragraph starts here and continues.
        """
        let split = text.distance(from: text.startIndex, to: text.range(of: "Second")!.lowerBound)
        let chunks = [
            PlaybackTextChunk(textStart: 0, textEnd: split, audioStart: 0),
            PlaybackTextChunk(textStart: split, textEnd: text.count, audioStart: 2.5)
        ]
        let blocks = SpeechLyricsView.blockRanges(in: text, chunks: chunks)
        #expect(blocks.count == 2)
        #expect(String(text[blocks[0]]).hasPrefix("👨‍👩‍👧‍👦 Café"))
        #expect(String(text[blocks[1]]).hasPrefix("Second paragraph"))
    }

    @Test("No chunks yields a single block over the whole text")
    func singleBlockWithoutChunks() {
        let text = "Hello there, world."
        let blocks = SpeechLyricsView.blockRanges(in: text, chunks: [])
        #expect(blocks.count == 1)
        #expect(blocks.first == text.startIndex..<text.endIndex)
    }

    @Test("Word start times interpolate monotonically within a chunk")
    func wordTimesAreMonotonic() throws {
        let text = "one two three four five six"
        let chunks = [PlaybackTextChunk(textStart: 0, textEnd: text.count, audioStart: 1)]
        let words = SpeechLyricsView.wordRanges(
            in: text,
            within: text.startIndex..<text.endIndex
        )
        #expect(words.count == 6)
        var times = words.map {
            SpeechLyricsView.startTime(
                forWordAt: text.distance(from: text.startIndex, to: $0.lowerBound),
                text: text,
                chunks: chunks,
                generatedDuration: 4
            )
        }
        #expect(times.first == 1)
        #expect(times.last! < 4)
        let sorted = times
        times.sort()
        #expect(times == sorted)
    }

    @Test("Word start times fall back to proportional mapping without chunks")
    func proportionalFallback() {
        let text = "abcd efgh"
        let midpoint = text.distance(from: text.startIndex, to: text.index(text.startIndex, offsetBy: 5))
        let time = SpeechLyricsView.startTime(
            forWordAt: midpoint,
            text: text,
            chunks: [],
            generatedDuration: 10
        )
        #expect(time > 5 && time < 6)
    }
}
