import Foundation
import SayItProtocol

/// Approximate word times are local to a synthesis chunk, never the whole live stream.
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
        let index = lower - 1
        let chunk = chunks[index]
        guard offset < chunk.textEnd else { return .infinity }
        return time(forOffset: offset, chunk: chunk, duration: duration(at: index, chunks: chunks))
    }

    static func wordIndex(
        at elapsed: TimeInterval,
        document: SpeechReaderDocument,
        chunks: [PlaybackTextChunk],
        generatedDuration: TimeInterval
    ) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, generatedDuration.isFinite,
              generatedDuration > elapsed, let lastToken = document.tokens.last else { return nil }
        let chunk: PlaybackTextChunk
        let duration: TimeInterval
        if chunks.isEmpty {
            // Old saved recordings have no chunk metadata. Their fixed audio duration
            // still permits a coarse proportional estimate.
            chunk = PlaybackTextChunk(
                textStart: 0, textEnd: lastToken.sourceRange.upperBound,
                audioStart: 0, audioEnd: generatedDuration
            )
            duration = generatedDuration
        } else {
            guard let index = chunkIndex(at: elapsed, chunks: chunks) else { return nil }
            chunk = chunks[index]
            duration = self.duration(at: index, chunks: chunks)
        }
        guard duration.isFinite, duration > 0,
              let first = document.wordIndex(atOrAfter: chunk.textStart),
              document.tokens[first].sourceRange.lowerBound < chunk.textEnd else { return nil }
        var end = document.wordIndex(atOrAfter: chunk.textEnd) ?? document.tokens.count
        if end < document.tokens.count, document.tokens[end].sourceRange.lowerBound < chunk.textEnd {
            end += 1
        }
        // Search only this chunk: ungenerated words and whitespace gaps must not
        // disturb the ordering required by binary search.
        let relative = activeWordIndex(at: elapsed, tokenCount: end - first) { index in
            time(
                forOffset: max(document.tokens[first + index].sourceRange.lowerBound, chunk.textStart),
                chunk: chunk, duration: duration
            )
        }
        return relative.map { first + $0 }
    }

    static func legacyTiming(forOffset offset: Int, textEnd: Int, duration: TimeInterval) -> TimeInterval {
        guard textEnd > 0, offset >= 0, offset < textEnd,
              duration.isFinite, duration > 0 else { return .infinity }
        return Double(offset) / Double(textEnd) * duration
    }

    private static func time(forOffset offset: Int, chunk: PlaybackTextChunk, duration: TimeInterval) -> TimeInterval {
        guard chunk.textEnd > chunk.textStart, chunk.audioStart.isFinite,
              duration.isFinite, duration > 0 else { return .infinity }
        let fraction = Double(offset - chunk.textStart) / Double(chunk.textEnd - chunk.textStart)
        return chunk.audioStart + min(max(fraction, 0), 1) * duration
    }

    private static func duration(at index: Int, chunks: [PlaybackTextChunk]) -> TimeInterval {
        let chunk = chunks[index]
        if let end = chunk.audioEnd { return end - chunk.audioStart }
        if index + 1 < chunks.count { return chunks[index + 1].audioStart - chunk.audioStart }
        // A growing generatedDuration would move already displayed words backward
        // on every PCM update. Keep the unfinished chunk's rate estimate fixed;
        // re-anchor once its true speech end arrives. Use the preceding completed
        // chunk's rate when available, with limits for pathological short chunks.
        var charactersPerSecond = 15.0
        if index > 0 {
            let previous = chunks[index - 1]
            if let end = previous.audioEnd, end > previous.audioStart {
                charactersPerSecond = min(max(
                    Double(previous.textEnd - previous.textStart) / (end - previous.audioStart), 5
                ), 30)
            }
        }
        return Double(max(chunk.textEnd - chunk.textStart, 1)) / charactersPerSecond
    }

    static func activeWordIndex(
        at elapsed: TimeInterval,
        tokenCount: Int,
        startTime: (Int) -> TimeInterval
    ) -> Int? {
        guard elapsed.isFinite, tokenCount > 0 else { return nil }
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
