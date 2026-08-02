import Foundation
import SayItProtocol

enum SpeechLyricsTimeline {
    enum Timing: Equatable {
        case chunk(index: Int, fraction: Double)
        case proportional(fraction: Double)
        case absolute(TimeInterval)
    }

    static func timing(
        forOffset offset: Int,
        textCount: Int,
        chunks: [PlaybackTextChunk],
        chunkIndex: inout Int
    ) -> Timing {
        guard !chunks.isEmpty else {
            return proportionalTiming(offset: offset, textCount: textCount)
        }
        while chunkIndex + 1 < chunks.count,
              chunks[chunkIndex + 1].textStart <= offset {
            chunkIndex += 1
        }
        guard chunks.indices.contains(chunkIndex) else { return .absolute(.infinity) }
        let chunk = chunks[chunkIndex]
        if offset < chunk.textStart {
            return .absolute(chunk.audioStart)
        }
        guard offset <= chunk.textEnd else {
            if chunkIndex + 1 < chunks.count {
                return .absolute(chunks[chunkIndex + 1].audioStart)
            }
            return .absolute(.infinity)
        }
        let length = max(chunk.textEnd - chunk.textStart, 1)
        return .chunk(
            index: chunkIndex,
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
        switch timing {
        case .chunk(let index, let fraction):
            guard chunks.indices.contains(index) else { return 0 }
            let chunk = chunks[index]
            let end = index + 1 < chunks.count
                ? chunks[index + 1].audioStart
                : max(generatedDuration, chunk.audioStart)
            return chunk.audioStart
                + fraction * max(end - chunk.audioStart, 0.001)
        case .proportional(let fraction):
            return fraction * max(generatedDuration, 0)
        case .absolute(let time):
            return time
        }
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
        .proportional(
            fraction: textCount > 0
                ? Double(offset) / Double(textCount)
                : 0
        )
    }
}
