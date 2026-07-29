import SayItProtocol
import SwiftUI

struct SpeechLyricsView: View {
    let text: String
    let chunks: [PlaybackTextChunk]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval

    private struct Block: Identifiable {
        let id: Int
        let range: Range<String.Index>
    }

    var body: some View {
        let blocks = self.blocks
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks) { block in
                        LyricsBlockView(
                            content: highlightedText(for: block),
                            showsChunkMarker: block.id != blocks.last?.id
                        )
                        .id(block.id)
                    }
                }
                .padding(.vertical, 24)
            }
            .mask(fadeMask)
            .onChange(of: currentBlockID, initial: true) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.35))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spoken text")
        .accessibilityValue(currentWord)
    }

    private var currentWord: String {
        guard let range = currentWordRange else { return "" }
        return String(text[range])
    }

    private struct LyricsBlockView: View {
        let content: AttributedString
        let showsChunkMarker: Bool

        var body: some View {
            Text(content)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChunkMarker {
                ChunkMarkerView()
            }
        }
    }

    private struct ChunkMarkerView: View {
        var body: some View {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 1)
                Image(systemName: "scissors")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.15),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var blocks: [Block] {
        guard !text.isEmpty else { return [] }
        guard !chunks.isEmpty else {
            return [Block(id: 0, range: text.startIndex..<text.endIndex)]
        }
        return chunks.enumerated().compactMap { index, chunk in
            guard chunk.textStart >= 0,
                  chunk.textEnd > chunk.textStart,
                  chunk.textEnd <= text.count,
                  let lower = text.index(
                    text.startIndex,
                    offsetBy: chunk.textStart,
                    limitedBy: text.endIndex
                  ),
                  let upper = text.index(
                    text.startIndex,
                    offsetBy: chunk.textEnd,
                    limitedBy: text.endIndex
                  ),
                  lower < upper else {
                return nil
            }
            return Block(id: index, range: lower..<upper)
        }
    }

    private var words: [Range<String.Index>] {
        text.ranges(of: #/\S+/#)
    }

    private var currentWordRange: Range<String.Index>? {
        var current: Range<String.Index>?
        for word in words where startTime(for: word) <= elapsed + 0.08 {
            current = word
        }
        return current
    }

    private var currentBlockID: Int? {
        guard let word = currentWordRange else { return blocks.first?.id }
        return blocks.last { $0.range.lowerBound <= word.lowerBound }?.id
            ?? blocks.first?.id
    }

    private func startTime(for word: Range<String.Index>) -> TimeInterval {
        let offset = text.distance(from: text.startIndex, to: word.lowerBound)
        guard !chunks.isEmpty,
              let index = chunks.lastIndex(where: { $0.textStart <= offset }) else {
            return proportionalTime(offset: offset)
        }
        let chunk = chunks[index]
        let length = max(chunk.textEnd - chunk.textStart, 1)
        let end = index + 1 < chunks.count
            ? chunks[index + 1].audioStart
            : max(generatedDuration, chunk.audioStart)
        let duration = max(end - chunk.audioStart, 0.001)
        let fraction = min(
            max(Double(offset - chunk.textStart) / Double(length), 0),
            1
        )
        return chunk.audioStart + fraction * duration
    }

    private func proportionalTime(offset: Int) -> TimeInterval {
        guard generatedDuration > 0, !text.isEmpty else { return 0 }
        return Double(offset) / Double(text.count) * generatedDuration
    }

    private func highlightedText(for block: Block) -> AttributedString {
        var attributed = AttributedString(String(text[block.range]))
        attributed.foregroundColor = .primary.opacity(0.45)
        guard let current = currentWordRange else { return attributed }

        if current.lowerBound > block.range.lowerBound {
            let pastEnd = min(current.lowerBound, block.range.upperBound)
            setColor(
                .primary.opacity(0.95),
                for: block.range.lowerBound..<pastEnd,
                in: &attributed
            )
        }
        let wordStart = max(current.lowerBound, block.range.lowerBound)
        let wordEnd = min(current.upperBound, block.range.upperBound)
        if wordStart < wordEnd {
            setColor(.accentColor, for: wordStart..<wordEnd, in: &attributed)
            setFont(.callout.weight(.semibold), for: wordStart..<wordEnd, in: &attributed)
        }
        return attributed
    }

    private func setColor(
        _ color: Color,
        for range: Range<String.Index>,
        in attributed: inout AttributedString
    ) {
        guard let lower = AttributedString.Index(
            range.lowerBound,
            within: attributed
        ),
        let upper = AttributedString.Index(
            range.upperBound,
            within: attributed
        ) else {
            return
        }
        attributed[lower..<upper].foregroundColor = color
    }

    private func setFont(
        _ font: Font,
        for range: Range<String.Index>,
        in attributed: inout AttributedString
    ) {
        guard let lower = AttributedString.Index(
            range.lowerBound,
            within: attributed
        ),
        let upper = AttributedString.Index(
            range.upperBound,
            within: attributed
        ) else {
            return
        }
        attributed[lower..<upper].font = font
    }
}
