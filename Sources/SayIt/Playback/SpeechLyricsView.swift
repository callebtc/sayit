import AppKit
import SayItProtocol
import SwiftUI

struct SpeechLyricsView: View {
    let text: String
    let chunks: [PlaybackTextChunk]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    var showsBlockSeparators = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var tokenization = Tokenization()
    @State private var autoFollow = true
    @State private var lastScrolledWord = -1
    @State private var scrollMetrics = ScrollMetrics()

    private struct Block: Identifiable {
        let id: Int
        var words: [WordToken] = []
    }

    private struct WordToken: Identifiable {
        let id: Int
        let blockID: Int
        let text: String
        let timing: SpeechLyricsTimeline.Timing
        var newlinesBefore: Int = 0
    }

    private struct Tokenization {
        var sourceText = ""
        var sourceChunks: [PlaybackTextChunk] = []
        var blocks: [Block] = []
        var tokens: [WordToken] = []
    }

    private struct ScrollMetrics: Equatable {
        var offset: Double = 0
        var contentHeight: Double = 1
        var containerHeight: Double = 1
    }

    private static let naturalSpaceWidth: Double = {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return Double((" " as NSString).size(withAttributes: [.font: font]).width)
    }()

    private var activeTokenization: Tokenization? {
        guard tokenization.sourceText == text, tokenization.sourceChunks == chunks else {
            return nil
        }
        return tokenization
    }

    private var blocks: [Block] {
        activeTokenization?.blocks ?? []
    }

    private var tokens: [WordToken] {
        activeTokenization?.tokens ?? []
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
        let currentWordIndex = currentWordIndex
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { block in
                    blockView(
                        for: block,
                        currentWordIndex: currentWordIndex
                    )
                }
            }
            .padding(.vertical, 24)
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func blockView(
        for block: Block,
        currentWordIndex: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            WordsFlowLayout(
                horizontalSpacing: Self.naturalSpaceWidth,
                verticalSpacing: 3
            ) {
                ForEach(block.words) { token in
                    wordView(
                        for: token,
                        currentWordIndex: currentWordIndex
                    )
                }
            }
            if showsBlockSeparators, block.id != blocks.last?.id {
                ChunkMarkerView()
            }
        }
        .id(Self.scrollID(forBlock: block.id))
    }

    private var currentWord: String {
        guard let index = currentWordIndex,
              tokens.indices.contains(index) else {
            return ""
        }
        return tokens[index].text
    }

    private var currentWordIndex: Int? {
        guard generatedDuration > 0 else { return nil }
        return SpeechLyricsTimeline.activeWordIndex(
            at: elapsed + 0.08,
            tokenCount: tokens.count
        ) { index in
            startTime(for: tokens[index])
        }
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

    private func wordView(
        for token: WordToken,
        currentWordIndex: Int?
    ) -> some View {
        let isCurrent = token.id == currentWordIndex
        let isPast = currentWordIndex.map { token.id < $0 } ?? false
        let seekTime = startTime(for: token)
        let canSeek = onSeek != nil && seekTime <= generatedDuration
        return Text(token.text)
            .font(.callout)
            .foregroundStyle(wordColor(isCurrent: isCurrent, isPast: isPast))
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.13 : 0))
                    .padding(.horizontal, -2.5)
                    .padding(.vertical, -1.5)
            }
            .scaleEffect(isCurrent ? 1.09 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canSeek else { return }
                onSeek?(seekTime)
            }
            .onHover { hovering in
                guard canSeek else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isCurrent)
            .id(Self.scrollID(forWord: token.id))
            .layoutValue(key: NewlinesBeforeKey.self, value: token.newlinesBefore)
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
            .padding(.vertical, 0)
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
        var chunkIndex = 0
        var offsetCursor = text.startIndex
        var offsetValue = 0
        let textCount = text.count
        for (blockID, range) in blockRanges.enumerated() {
            var block = Block(id: blockID)
            var previousUpper = range.lowerBound
            for wordRange in Self.wordRanges(in: text, within: range) {
                let offsetRange: Range<Int>
                if offsetCursor <= wordRange.lowerBound {
                    let leadingCount = text.distance(
                        from: offsetCursor,
                        to: wordRange.lowerBound
                    )
                    let wordCount = text.distance(
                        from: wordRange.lowerBound,
                        to: wordRange.upperBound
                    )
                    let lowerOffset = offsetValue + leadingCount
                    offsetRange = lowerOffset..<(lowerOffset + wordCount)
                    offsetCursor = wordRange.upperBound
                    offsetValue = offsetRange.upperBound
                } else {
                    offsetRange = Self.offsetRange(
                        for: wordRange,
                        in: text
                    )
                }
                let newlines = text[previousUpper..<wordRange.lowerBound]
                    .reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                let token = WordToken(
                    id: index,
                    blockID: blockID,
                    text: String(text[wordRange]),
                    timing: SpeechLyricsTimeline.timing(
                        forOffset: offsetRange.lowerBound,
                        textCount: textCount,
                        chunks: chunks,
                        chunkIndex: &chunkIndex
                    ),
                    newlinesBefore: newlines
                )
                block.words.append(token)
                newTokens.append(token)
                previousUpper = wordRange.upperBound
                index += 1
            }
            newBlocks.append(block)
        }
        tokenization = Tokenization(
            sourceText: text,
            sourceChunks: chunks,
            blocks: newBlocks,
            tokens: newTokens
        )
    }

    private func startTime(for token: WordToken) -> TimeInterval {
        SpeechLyricsTimeline.startTime(
            for: token.timing,
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
        let textCount = text.count
        var offsetCursor = 0
        var indexCursor = text.startIndex
        var boundaries = [text.startIndex]
        boundaries.reserveCapacity(chunks.count + 1)
        for chunk in chunks {
            guard chunk.textStart >= 0,
                  chunk.textEnd > chunk.textStart,
                  chunk.textEnd <= textCount,
                  chunk.textStart >= offsetCursor,
                  let boundary = text.index(
                    indexCursor,
                    offsetBy: chunk.textStart - offsetCursor,
                    limitedBy: text.endIndex
                  ) else {
                continue
            }
            if boundary > boundaries[boundaries.count - 1] {
                boundaries.append(boundary)
            }
            offsetCursor = chunk.textStart
            indexCursor = boundary
        }
        if boundaries[boundaries.count - 1] < text.endIndex {
            boundaries.append(text.endIndex)
        }
        return zip(boundaries, boundaries.dropFirst()).map {
            $0.0..<$0.1
        }
    }

    nonisolated static func wordRanges(
        in text: String,
        within range: Range<String.Index>
    ) -> [Range<String.Index>] {
        text[range].ranges(of: #/\S+/#).map { $0 }
    }

    nonisolated static func offsetRange(
        for range: Range<String.Index>,
        in text: String
    ) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }

}

private struct NewlinesBeforeKey: LayoutValueKey {
    static let defaultValue = 0
}

private struct WordsFlowLayout: Layout {
    var horizontalSpacing: Double = 3.5
    var verticalSpacing: Double = 3
    var paragraphSpacing: Double = 8

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
            let newlines = subview[NewlinesBeforeKey.self]
            if !positions.isEmpty, newlines > 0 {
                x = 0
                y += rowHeight + verticalSpacing
                    + (newlines > 1 ? paragraphSpacing : 0)
                rowHeight = 0
            } else if x > 0, x + size.width > maxWidth {
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
