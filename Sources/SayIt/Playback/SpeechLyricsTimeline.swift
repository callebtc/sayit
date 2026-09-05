import Foundation
import SayItProtocol

/// Follow known speech boundaries. Character fractions are not audio alignment.
enum SpeechLyricsTimeline {
    static func chunkIndex(at elapsed: TimeInterval, chunks: [PlaybackTextChunk]) -> Int? {
        guard elapsed.isFinite else { return nil }
        guard let index = activeWordIndex(
            at: elapsed, tokenCount: chunks.count,
            startTime: { chunks[$0].audioStart }
        ) else { return nil }
        let chunk = chunks[index]
        if let end = chunk.audioEnd, elapsed >= end { return nil }
        return index
    }

    static func timing(forOffset offset: Int, chunks: [PlaybackTextChunk]) -> TimeInterval {
        var lower = 0
        var upper = chunks.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if chunks[middle].textStart <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return .infinity }
        let chunk = chunks[lower - 1]
        guard offset < chunk.textEnd else { return .infinity }
        return chunk.audioStart
    }

    static func activeWordIndex(
        at elapsed: TimeInterval,
        tokenCount: Int,
        startTime: (Int) -> TimeInterval
    ) -> Int? {
        guard tokenCount > 0 else { return nil }
        var lowerBound = 0
        var upperBound = tokenCount
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if startTime(middle) <= elapsed {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound > 0 ? lowerBound - 1 : nil
    }
}
