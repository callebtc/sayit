import Foundation
import SayItProtocol

enum SpeechLyricsTimeline {
    struct Timing: Equatable {
        let chunkIndex: Int?
        let fraction: Double
    }

    static func timing(
        forOffset offset: Int,
        textCount: Int,
        chunks: [PlaybackTextChunk],
        chunkIndex: inout Int
    ) -> Timing {
        while chunkIndex + 1 < chunks.count,
              chunks[chunkIndex + 1].textStart <= offset {
            chunkIndex += 1
        }
        guard chunks.indices.contains(chunkIndex) else {
            return proportionalTiming(offset: offset, textCount: textCount)
        }
        let chunk = chunks[chunkIndex]
        guard chunk.textStart <= offset, offset <= chunk.textEnd else {
            return proportionalTiming(offset: offset, textCount: textCount)
        }
        let length = max(chunk.textEnd - chunk.textStart, 1)
        return Timing(
            chunkIndex: chunkIndex,
            fraction: min(
                max(Double(offset - chunk.textStart) / Double(length), 0),
                1
            )
        )
    }

    static func startTime(
        for timing: Timing,
        chunks: [PlaybackTextChunk],
        generatedDuration: TimeInterval
    ) -> TimeInterval {
        guard let index = timing.chunkIndex else {
            return timing.fraction * max(generatedDuration, 0)
        }
        guard chunks.indices.contains(index) else { return 0 }
        let chunk = chunks[index]
        let end = index + 1 < chunks.count
            ? chunks[index + 1].audioStart
            : max(generatedDuration, chunk.audioStart)
        return chunk.audioStart
            + timing.fraction * max(end - chunk.audioStart, 0.001)
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

    private static func proportionalTiming(
        offset: Int,
        textCount: Int
    ) -> Timing {
        Timing(
            chunkIndex: nil,
            fraction: textCount > 0
                ? Double(offset) / Double(textCount)
                : 0
        )
    }
}
