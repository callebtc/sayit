import SayItProtocol
import SwiftUI

struct SpeechLyricsView: View {
    let text: String
    let chunks: [PlaybackTextChunk]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval

    @State private var blocks: [Block] = []
    @State private var tokens: [WordToken] = []
    @State private var autoFollow = true
    @State private var lastScrolledWord = -1
    @State private var scrollMetrics = ScrollMetrics()

    private struct Block: Identifiable {
        let id: Int
        let range: Range<String.Index>
        var words: [WordToken] = []
    }

    private struct WordToken: Identifiable {
        let id: Int
        let range: Range<String.Index>
        let blockID: Int
    }

    private struct ScrollMetrics: Equatable {
        var offset: Double = 0
        var contentHeight: Double = 1
        var containerHeight: Double = 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .scrollIndicators(.never)
                .mask(fadeMask)
                .onScrollGeometryChange(
                    for: ScrollMetrics.self,
                    of: { geometry in
                        ScrollMetrics(
                            offset: geometry.contentOffset.y,
                            contentHeight: geometry.contentSize.height,
                            containerHeight: geometry.containerSize.height
                        )
                    },
                    action: { _, metrics in
                        scrollMetrics = metrics
                    }
                )
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking {
                        withAnimation(DesignTokens.quickAnimation) {
                            autoFollow = false
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    minimalScrollIndicator
                }
                .overlay(alignment: .bottomTrailing) {
                    followButton(proxy: proxy)
                }
                .onChange(of: currentWordIndex, initial: true) { _, newValue in
                    follow(newValue, proxy: proxy)
                }
        }
        .onAppear(perform: rebuildTokens)
        .onChange(of: text) { _, _ in
            autoFollow = true
            lastScrolledWord = -1
            rebuildTokens()
        }
        .onChange(of: chunks) { _, _ in rebuildTokens() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spoken text")
        .accessibilityValue(currentWord)
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { block in
                    blockView(for: block)
                }
            }
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func blockView(for block: Block) -> some View {
        WordsFlowLayout(horizontalSpacing: 3.5, verticalSpacing: 3) {
            ForEach(block.words) { token in
                wordView(for: token)
            }
        }
        .id(Self.scrollID(forBlock: block.id))
        if block.id != blocks.last?.id {
            ChunkMarkerView()
        }
    }

    private var currentWord: String {
        guard let index = currentWordIndex, tokens.indices.contains(index) else { return "" }
        return String(text[tokens[index].range])
    }

    private var currentWordIndex: Int? {
        guard !tokens.isEmpty else { return nil }
        var current: Int?
        for (index, token) in tokens.enumerated() {
            guard startTime(for: token.range) <= elapsed + 0.08 else { break }
            current = index
        }
        return current
    }

    private func follow(_ wordIndex: Int?, proxy: ScrollViewProxy) {
        guard autoFollow, let wordIndex else { return }
        let blockID = wordIndex < tokens.count ? tokens[wordIndex].blockID : nil
        let lastBlockID = lastScrolledWord >= 0 && lastScrolledWord < tokens.count
            ? tokens[lastScrolledWord].blockID
            : nil
        let jumped = lastScrolledWord < 0 || abs(wordIndex - lastScrolledWord) > 4
        let blockChanged = blockID != lastBlockID
        guard jumped || blockChanged || wordIndex - lastScrolledWord >= 2 else { return }
        withAnimation(.smooth(duration: 0.55)) {
            if blockChanged || jumped, let blockID {
                proxy.scrollTo(Self.scrollID(forBlock: blockID), anchor: UnitPoint(x: 0.5, y: 0.3))
            }
            proxy.scrollTo(Self.scrollID(forWord: wordIndex), anchor: UnitPoint(x: 0.5, y: 0.42))
        }
        lastScrolledWord = wordIndex
    }

    private func followButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(DesignTokens.quickAnimation) {
                autoFollow = true
            }
            lastScrolledWord = -1
            follow(currentWordIndex, proxy: proxy)
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume following the spoken text")
        .padding(6)
        .opacity(autoFollow ? 0 : 1)
        .scaleEffect(autoFollow ? 0.6 : 1)
        .allowsHitTesting(!autoFollow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: autoFollow)
    }

    private var minimalScrollIndicator: some View {
        let track = max(scrollMetrics.containerHeight - 48, 1)
        let visibleFraction = min(
            scrollMetrics.containerHeight / max(scrollMetrics.contentHeight, 1),
            1
        )
        let thumbHeight = max(16, track * visibleFraction)
        let scrollable = max(scrollMetrics.contentHeight - scrollMetrics.containerHeight, 1)
        let progress = min(max(scrollMetrics.offset / scrollable, 0), 1)
        return Capsule()
            .fill(.primary.opacity(0.16))
            .frame(width: 2, height: visibleFraction >= 1 ? 0 : thumbHeight)
            .offset(y: progress * (track - thumbHeight))
            .frame(height: track, alignment: .top)
            .padding(.trailing, 2)
            .allowsHitTesting(false)
    }

    private func wordView(for token: WordToken) -> some View {
        let isCurrent = token.id == currentWordIndex
        let isPast = currentWordIndex.map { token.id < $0 } ?? false
        return Text(text[token.range])
            .font(.callout)
            .foregroundStyle(wordColor(isCurrent: isCurrent, isPast: isPast))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.13 : 0))
            }
            .scaleEffect(isCurrent ? 1.09 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isCurrent)
            .animation(.smooth(duration: 0.35), value: isPast)
            .id(Self.scrollID(forWord: token.id))
    }

    private func wordColor(isCurrent: Bool, isPast: Bool) -> Color {
        if isCurrent { return .accentColor }
        return isPast ? .primary.opacity(0.9) : .primary.opacity(0.45)
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

    private func rebuildTokens() {
        let blockRanges = Self.blockRanges(in: text, chunks: chunks)
        var newBlocks: [Block] = []
        var newTokens: [WordToken] = []
        var index = 0
        for (blockID, range) in blockRanges.enumerated() {
            var block = Block(id: blockID, range: range)
            for wordRange in Self.wordRanges(in: text, within: range) {
                let token = WordToken(id: index, range: wordRange, blockID: blockID)
                block.words.append(token)
                newTokens.append(token)
                index += 1
            }
            newBlocks.append(block)
        }
        blocks = newBlocks
        tokens = newTokens
    }

    private func startTime(for word: Range<String.Index>) -> TimeInterval {
        Self.startTime(
            forWordAt: text.distance(from: text.startIndex, to: word.lowerBound),
            text: text,
            chunks: chunks,
            generatedDuration: generatedDuration
        )
    }

    private static func scrollID(forBlock id: Int) -> String { "block-\(id)" }

    private static func scrollID(forWord id: Int) -> String { "word-\(id)" }

    nonisolated static func blockRanges(
        in text: String,
        chunks: [PlaybackTextChunk]
    ) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        guard !chunks.isEmpty else { return [text.startIndex..<text.endIndex] }
        return chunks.compactMap { chunk in
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
            return lower..<upper
        }
    }

    nonisolated static func wordRanges(
        in text: String,
        within range: Range<String.Index>
    ) -> [Range<String.Index>] {
        text[range].ranges(of: #/\S+/#).map { $0 }
    }

    nonisolated static func startTime(
        forWordAt offset: Int,
        text: String,
        chunks: [PlaybackTextChunk],
        generatedDuration: TimeInterval
    ) -> TimeInterval {
        guard !chunks.isEmpty,
              let index = chunks.lastIndex(where: { $0.textStart <= offset }) else {
            return proportionalTime(offset: offset, text: text, generatedDuration: generatedDuration)
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

    private nonisolated static func proportionalTime(
        offset: Int,
        text: String,
        generatedDuration: TimeInterval
    ) -> TimeInterval {
        guard generatedDuration > 0, !text.isEmpty else { return 0 }
        return Double(offset) / Double(text.count) * generatedDuration
    }
}

private struct WordsFlowLayout: Layout {
    var horizontalSpacing: Double = 3.5
    var verticalSpacing: Double = 3

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let position = arrangement.positions[index]
            let size = arrangement.sizes[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private struct Arrangement {
        var size: CGSize
        var positions: [CGPoint]
        var sizes: [CGSize]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: Double = 0
        var y: Double = 0
        var rowHeight: Double = 0
        var maxX: Double = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
            maxX = max(maxX, x - horizontalSpacing)
        }
        return Arrangement(
            size: CGSize(width: maxX, height: y + rowHeight),
            positions: positions,
            sizes: sizes
        )
    }
}
