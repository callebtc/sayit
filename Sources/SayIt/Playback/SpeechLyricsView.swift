import AppKit
import SayItProtocol
import SwiftUI

struct SpeechLyricsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let chunks: [PlaybackTextChunk]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    var showsHighlight = true
    var showsBlockSeparators = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var tokenization = SpeechReaderDocument.empty
    @State private var isFollowing = true
    @State private var lastScrolledWord = -1
    @State private var scrollMetrics = ScrollMetrics()
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var visibleWordIDs: Set<Int> = []
    @State private var hasMeasuredVisibleWords = false

    private typealias Block = SpeechReaderDocument.Block
    private typealias WordToken = SpeechReaderDocument.Word

    private struct ScrollMetrics: Equatable {
        var offset: Double = 0
        var contentHeight: Double = 1
        var containerHeight: Double = 1
    }

    private static let naturalSpaceWidth: Double = {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return Double((" " as NSString).size(withAttributes: [.font: font]).width)
    }()

    private var activeTokenization: SpeechReaderDocument? {
        guard tokenization.sourceText == text else {
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
        Group {
            scrollContent
                .scrollPosition($scrollPosition)
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
                    guard phase == .tracking || phase == .interacting else { return }
                    isFollowing = false
                }
                .overlay(alignment: .trailing) {
                    minimalScrollIndicator
                }
                .overlay(alignment: .bottomTrailing) {
                    followButton
                }
                .onChange(of: currentWordIndex, initial: true) { _, newValue in
                    follow(newValue)
                }
                .onAppear {
                    attachFollow()
                }
                .onChange(of: text) { _, _ in
                    attachFollow()
                }
                .task(id: text) {
                    guard activeTokenization == nil else { return }
                    let source = text
                    let work = Task.detached(priority: .userInitiated) {
                        try SpeechReaderDocument.build(source)
                    }
                    do {
                        let document = try await withTaskCancellationHandler {
                            try await work.value
                        } onCancel: {
                            work.cancel()
                        }
                        try Task.checkCancellation()
                        tokenization = document
                        attachFollow()
                    } catch is CancellationError {
                        // A new document or dismissal invalidates this result.
                    } catch {
                        tokenization = .empty
                    }
                }
        }
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
            .scrollTargetLayout()
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
        .id(block.id)
    }

    private var currentWord: String {
        guard let index = currentWordIndex,
              tokens.indices.contains(index) else {
            return ""
        }
        guard let chunk = currentChunk else { return "" }
        return tokens[index...]
            .prefix { $0.sourceRange.lowerBound < chunk.textEnd }
            .map(\.text).joined(separator: " ")
    }

    private var currentChunk: PlaybackTextChunk? {
        guard showsHighlight, generatedDuration > 0,
              let index = SpeechLyricsTimeline.chunkIndex(at: elapsed, chunks: chunks)
        else { return nil }
        return chunks[index]
    }

    private var currentWordIndex: Int? {
        guard let chunk = currentChunk else { return nil }
        return activeTokenization?.wordIndex(atOrAfter: chunk.textStart)
    }

    private func attachFollow() {
        isFollowing = true
        lastScrolledWord = -1
        visibleWordIDs = []
        hasMeasuredVisibleWords = false
        scrollPosition = ScrollPosition(idType: Int.self)
        follow(currentWordIndex)
    }

    private func follow(_ wordIndex: Int?) {
        guard isFollowing, let wordIndex else { return }
        let blockID = wordIndex < tokens.count ? tokens[wordIndex].blockID : nil
        let lastBlockID = lastScrolledWord >= 0 && lastScrolledWord < tokens.count
            ? tokens[lastScrolledWord].blockID
            : nil
        let jumped = lastScrolledWord < 0 || abs(wordIndex - lastScrolledWord) > 4
        let blockChanged = blockID != lastBlockID
        guard jumped || blockChanged || wordIndex - lastScrolledWord >= 2 else { return }
        let target = blockID ?? 0
        if reduceMotion || jumped || blockChanged {
            scrollPosition.scrollTo(
                id: target,
                anchor: UnitPoint(x: 0.5, y: 0.42)
            )
        } else {
            withAnimation(.smooth(duration: 0.55)) {
                scrollPosition.scrollTo(
                    id: target,
                    anchor: UnitPoint(x: 0.5, y: 0.42)
                )
            }
        }
        lastScrolledWord = wordIndex
    }

    private var followButton: some View {
        Button(
            "Resume following the spoken text",
            systemImage: "arrow.down.to.line",
            action: { attachFollow() }
        )
        .labelStyle(.iconOnly)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(6)
        .background(.ultraThinMaterial, in: Circle())
        .buttonStyle(.plain)
        .padding(6)
        .opacity(showsFollowButton ? 1 : 0)
        .scaleEffect(showsFollowButton ? 1 : 0.6)
        .allowsHitTesting(showsFollowButton)
        .animation(
            .spring(response: 0.3, dampingFraction: 0.7),
            value: showsFollowButton
        )
    }

    private var showsFollowButton: Bool {
        if !isFollowing { return true }
        guard hasMeasuredVisibleWords, let currentWordIndex else { return false }
        return !visibleWordIDs.contains(currentWordIndex)
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
        let isCurrent = currentChunk.map {
            token.sourceRange.overlaps($0.textStart..<$0.textEnd)
        } ?? false
        let isPast = currentWordIndex.map { token.id < $0 } ?? false
        let seekTime = startTime(for: token)
        let isProcessed = seekTime <= generatedDuration
        let canSeek = onSeek != nil && isProcessed
        return Text(token.text)
            .font(.callout)
            .foregroundStyle(
                wordColor(isCurrent: isCurrent, isPast: isPast, isProcessed: isProcessed)
            )
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.13 : 0))
                    .padding(.horizontal, -2.5)
                    .padding(.vertical, -1.5)
            }
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
            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                setWordVisibility(token.id, isVisible: isVisible)
            }
            .layoutValue(key: NewlinesBeforeKey.self, value: token.newlinesBefore)
            .layoutValue(key: JoinsPreviousKey.self, value: token.joinsPrevious)
    }

    private func setWordVisibility(_ id: Int, isVisible: Bool) {
        hasMeasuredVisibleWords = true
        if isVisible {
            visibleWordIDs.insert(id)
        } else {
            visibleWordIDs.remove(id)
        }
    }

    private func wordColor(
        isCurrent: Bool,
        isPast: Bool,
        isProcessed: Bool
    ) -> Color {
        if isCurrent { return .accentColor }
        if isPast { return .primary.opacity(0.9) }
        return isProcessed ? .primary.opacity(0.45) : .primary.opacity(0.22)
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

    private func startTime(for token: WordToken) -> TimeInterval {
        SpeechLyricsTimeline.timing(
            forOffset: token.sourceRange.lowerBound,
            chunks: chunks
        )
    }

    private static func scrollID(forWord id: Int) -> String { "word-\(id)" }


}

private struct JoinsPreviousKey: LayoutValueKey {
    static let defaultValue = false
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
        cache: inout [Double: Arrangement]
    ) -> CGSize {
        cachedArrangement(proposal: proposal, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [Double: Arrangement]
    ) {
        let arrangement = cachedArrangement(
            proposal: proposal, subviews: subviews, cache: &cache
        )
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

    struct Arrangement {
        var size: CGSize
        var positions: [CGPoint]
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> [Double: Arrangement] { [:] }

    func updateCache(_ cache: inout [Double: Arrangement], subviews: Subviews) {
        cache.removeAll(keepingCapacity: true)
    }

    private func cachedArrangement(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [Double: Arrangement]
    ) -> Arrangement {
        let width = proposal.width ?? .infinity
        if let arrangement = cache[width] { return arrangement }
        let arrangement = arrange(proposal: proposal, subviews: subviews)
        // Resizing must not retain an arrangement for every intermediate width.
        if cache.count >= 3 { cache.removeAll(keepingCapacity: true) }
        cache[width] = arrangement
        return arrangement
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
            if x > 0, subview[JoinsPreviousKey.self] { x -= horizontalSpacing }
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
