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
        var chunkIndex = 0
        var times = words.map {
            let timing = SpeechLyricsTimeline.timing(
                forOffset: text.distance(
                    from: text.startIndex,
                    to: $0.lowerBound
                ),
                textCount: text.count,
                chunks: chunks,
                chunkIndex: &chunkIndex
            )
            return SpeechLyricsTimeline.startTime(
                for: timing,
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
        let midpoint = text.distance(
            from: text.startIndex,
            to: text.index(text.startIndex, offsetBy: 5)
        )
        var chunkIndex = 0
        let timing = SpeechLyricsTimeline.timing(
            forOffset: midpoint,
            textCount: text.count,
            chunks: [],
            chunkIndex: &chunkIndex
        )
        let time = SpeechLyricsTimeline.startTime(
            for: timing,
            chunks: [],
            generatedDuration: 10
        )
        #expect(time > 5 && time < 6)
    }

    @Test("Active word lookup is logarithmic for long transcripts")
    func activeWordBinarySearch() {
        let times = (0..<100_000).map { Double($0) * 0.1 }
        var lookupCount = 0

        let index = SpeechLyricsTimeline.activeWordIndex(
            at: 5_432.15,
            tokenCount: times.count
        ) { candidate in
            lookupCount += 1
            return times[candidate]
        }

        #expect(index == 54_321)
        #expect(lookupCount <= 17)
    }
}
