import AppKit
import SayItProtocol
import SwiftUI

struct SpeechLyricsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let text: String
    let chunks: [PlaybackTextChunk]
    let elapsed: TimeInterval
    let generatedDuration: TimeInterval
    var showsHighlight = true
    var showsBlockSeparators = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var tokenization = SpeechReaderDocument.empty
    @State private var readerLayout = SpeechReaderLayout.empty
    @State private var contentWidth: Double = 0
    @State private var laidOutWidth: Double = 0
    @State private var laidOutTypography: SpeechReaderTypography?
    @State private var pendingScrollWord: Int?
    @State private var layoutRevision = 0
    @State private var isFollowing = true
    @State private var wordFrames: [Int: CGRect] = [:]
    @State private var scrollMetrics = ScrollMetrics()
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var visibleWordIDs: Set<Int> = []
    @State private var hasMeasuredVisibleWords = false

    private typealias Block = SpeechReaderLayout.Block
    private typealias WordToken = SpeechReaderDocument.Word

    private struct ScrollMetrics: Equatable {
        var offset: Double = 0
        var contentHeight: Double = 1
        var containerHeight: Double = 1
    }

    private struct WordGeometry: Equatable {
        let frame: CGRect
        let layoutRevision: Int
    }

    private var typography: SpeechReaderTypography {
        SpeechReaderTypography(font: NSFont.preferredFont(forTextStyle: .callout))
    }

    private struct LayoutRequest: Equatable, Sendable {
        let text: String
        let width: Double
        let typography: SpeechReaderTypography
        let dynamicTypeSize: DynamicTypeSize
    }

    private var layoutRequest: LayoutRequest {
        LayoutRequest(text: text, width: contentWidth, typography: typography, dynamicTypeSize: dynamicTypeSize)
    }

    private var activeTokenization: SpeechReaderDocument? {
        guard tokenization.sourceText == text else {
            return nil
        }
        return tokenization
    }

    private var blocks: [Block] {
        activeTokenization == nil ? [] : readerLayout.blocks
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
                .onChange(of: scrollPosition.isPositionedByUser) { _, userPositioned in
                    // Also cover wheel/keyboard scrolling without a tracking phase.
                    if userPositioned { isFollowing = false }
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
                    wordFrames = [:]
                    visibleWordIDs = []
                    hasMeasuredVisibleWords = false
                    attachFollow()
                }
                .onGeometryChange(for: Double.self) { geometry in
                    max(0, geometry.size.width - 8)
                } action: { width in
                    contentWidth = width
                }
                .task(id: layoutRequest) {
                    await updateLayout(layoutRequest)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spoken text")
        .accessibilityValue(currentWord)
    }

    private var scrollContent: some View {
        let currentWordIndex = currentWordIndex
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
        SpeechReaderBlockLayout(block: block, width: laidOutWidth) {
            ForEach(block.placements) { placement in
                wordView(for: tokens[placement.id], currentWordIndex: currentWordIndex)
            }
        }
        .padding(.top, block.spacingBefore)
        .overlay(alignment: .bottom) {
            if showsBlockSeparators, block.id != blocks.last?.id {
                ChunkMarkerView().allowsHitTesting(false)
            }
        }
        .id(block.id)
    }

    private func updateLayout(_ request: LayoutRequest) async {
        guard request.width > 0 else { return }
        let existing = activeTokenization
        // Width changes retain a source word, never an obsolete visual block ID.
        let anchor = isFollowing ? currentWordIndex : visibleWordIDs.min()
        let work = Task.detached(priority: .userInitiated) {
            let document = try existing ?? SpeechReaderDocument.build(request.text)
            let layout = try request.typography.layout(document: document, width: request.width)
            return (document, layout)
        }
        do {
            let (document, layout) = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            wordFrames = [:]
            visibleWordIDs = []
            hasMeasuredVisibleWords = false
            tokenization = document
            readerLayout = layout
            laidOutWidth = request.width
            laidOutTypography = request.typography
            layoutRevision &+= 1
            let target = isFollowing ? currentWordIndex : anchor
            pendingScrollWord = target
            if let target, let blockID = layout.blockID(forWord: target) {
                scrollPosition.scrollTo(id: blockID, anchor: .top)
            }
        } catch is CancellationError {
            // A newer width, document, or dismissal invalidates this result.
        } catch {
            tokenization = .empty
            readerLayout = .empty
        }
    }

    private var currentWord: String {
        guard let index = currentWordIndex,
              tokens.indices.contains(index) else {
            return ""
        }
        return tokens[index].text
    }

    private var currentWordIndex: Int? {
        guard showsHighlight, let document = activeTokenization else { return nil }
        return SpeechLyricsTimeline.wordIndex(
            at: elapsed, document: document, chunks: chunks,
            generatedDuration: generatedDuration
        )
    }

    private func attachFollow() {
        isFollowing = true
        follow(currentWordIndex)
    }

    private func follow(_ wordIndex: Int?) {
        guard isFollowing, let wordIndex else { return }
        guard tokens.indices.contains(wordIndex) else { return }
        // Lazy stacks cannot resolve an offscreen word nested in a custom layout.
        // First materialize its stable block; the word's geometry then refines
        // the position. Never use accumulated height estimates for distant seeks.
        if !visibleWordIDs.contains(wordIndex) {
            scrollPosition.scrollTo(
                id: readerLayout.blockID(forWord: wordIndex) ?? wordIndex,
                anchor: UnitPoint(x: 0.5, y: 0.42)
            )
        }
        if let frame = wordFrames[wordIndex] {
            followWordFrame(frame, wordID: wordIndex)
        }
    }

    private func followWordFrame(_ frame: CGRect, wordID: Int) {
        guard currentWordIndex == wordID else { return }
        guard isFollowing,
              let offset = SpeechReaderScroll.targetOffset(
                wordFrame: frame, viewportHeight: scrollMetrics.containerHeight,
                contentOffset: scrollMetrics.offset
              ) else { return }
        // Do not queue an animation per spoken word: a new word or seek must
        // immediately supersede the old target. The comfort band avoids jitter.
        scrollPosition.scrollTo(y: offset)
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
        let revision = layoutRevision
        let isCurrent = token.id == currentWordIndex
        let isPast = currentWordIndex.map { token.id < $0 } ?? false
        let seekTime = startTime(for: token)
        let isProcessed = seekTime.isFinite && seekTime < generatedDuration
        let canSeek = onSeek != nil && isProcessed
        return Text(token.text)
            .font(Font((laidOutTypography ?? typography).font))
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isCurrent)
            .id(Self.scrollID(forWord: token.id))
            .onGeometryChange(for: WordGeometry.self) { geometry in
                WordGeometry(
                    frame: geometry.frame(in: .scrollView(axis: .vertical)),
                    layoutRevision: revision
                )
            } action: { measurement in
                guard measurement.layoutRevision == layoutRevision else { return }
                let frame = measurement.frame
                wordFrames[token.id] = frame
                // Reflow may retain a view whose visibility did not change. Its
                // new geometry must still repopulate the visible-word set.
                let visibleHeight = max(0, min(frame.maxY, scrollMetrics.containerHeight) - max(frame.minY, 0))
                setWordVisibility(token.id, isVisible: visibleHeight >= frame.height * 0.5)
                if pendingScrollWord == token.id {
                    pendingScrollWord = nil
                    if !isFollowing {
                        scrollPosition.scrollTo(y: max(0, scrollMetrics.offset + frame.minY))
                    }
                }
                followWordFrame(frame, wordID: token.id)
            }
            .onDisappear {
                guard revision == layoutRevision else { return }
                wordFrames.removeValue(forKey: token.id)
                visibleWordIDs.remove(token.id)
            }
            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                guard revision == layoutRevision else { return }
                setWordVisibility(token.id, isVisible: isVisible)
            }
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
        if chunks.isEmpty {
            return SpeechLyricsTimeline.legacyTiming(
                forOffset: token.sourceRange.lowerBound,
                textEnd: tokens.last?.sourceRange.upperBound ?? 0,
                duration: generatedDuration
            )
        }
        return SpeechLyricsTimeline.timing(
            forOffset: token.sourceRange.lowerBound, chunks: chunks
        )
    }

    private static func scrollID(forWord id: Int) -> String { "word-\(id)" }


}
