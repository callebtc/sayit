import AppKit
import Foundation
import Testing
@testable import SayIt

@Suite("Reader line layout")
struct SpeechReaderLayoutTests {
    private func layout(_ text: String, width: Double) throws -> SpeechReaderLayout {
        try SpeechReaderLayout.build(
            document: SpeechReaderDocument.build(text), width: width, spaceWidth: 1
        ) { CGSize(width: Double($0.count), height: 10) }
    }

    @Test("The old 32-word boundary cannot force a line break")
    func wordLimitDoesNotBreakLines() throws {
        let result = try layout(Array(repeating: "word", count: 40).joined(separator: " "), width: 200)
        #expect(result.blocks.count == 1)
        #expect(result.blocks[0].lineCount == 1)
        #expect(result.blocks[0].placements[32].frame.minY == 0)
        #expect(result.blocks[0].placements[32].frame.minX == 160)
    }

    @Test("The old 512-character boundary cannot force a line break")
    func characterLimitDoesNotBreakLines() throws {
        let result = try layout(Array(repeating: String(repeating: "x", count: 100), count: 6).joined(separator: " "), width: 610)
        #expect(result.blocks.count == 1)
        #expect(result.blocks[0].lineCount == 1)
        #expect(result.blocks[0].placements.last?.frame.minY == 0)
    }

    @Test("A sentence continues after but whenever the next word fits")
    func sentenceContinuation() throws {
        let text = "The new build is also interesting, but it’s a smaller derivative with a custom runtime."
        let result = try layout(text, width: 60)
        let placements = result.blocks.flatMap(\.placements)
        #expect(placements[7].frame.minY == placements[6].frame.minY)
        #expect(placements[8].frame.minY == placements[7].frame.minY)
    }

    @Test("Only complete lines are grouped and block joins use normal line spacing")
    func completeLines() throws {
        let result = try layout(Array(repeating: "one two", count: 20).joined(separator: " "), width: 7)
        #expect(result.blocks.count == 3)
        #expect(result.blocks.map(\.lineCount) == [8, 8, 4])
        #expect(result.blocks.map(\.spacingBefore) == [0, 3, 3])
        #expect(result.blocks.map(\.id) == [0, 16, 32])
        #expect(result.blocks.flatMap(\.placements).map(\.id) == Array(0..<40))
        #expect(result.blocks.allSatisfy { $0.placements.allSatisfy { $0.frame.maxX <= 7 } })
    }

    @Test("Explicit newlines and paragraph spacing survive at a block boundary")
    func sourceBreaks() throws {
        let text = Array(repeating: "line", count: 8).joined(separator: "\n") + "\n\nparagraph"
        let result = try layout(text, width: 100)
        #expect(result.blocks.map(\.lineCount) == [8, 1])
        #expect(result.blocks[1].spacingBefore == 11)
        #expect(result.blocks[0].placements[1].frame.minY == 13)
    }

    @Test("Resizing maps the same source word to its new lazy block")
    func resizeAndSeek() throws {
        let text = Array(repeating: "one two", count: 100).joined(separator: " ")
        let narrow = try layout(text, width: 7)
        let wide = try layout(text, width: 15)
        #expect(narrow.blockID(forWord: 100) == 96)
        #expect(wide.blockID(forWord: 100) == 96)
        #expect(narrow.blockID(forWord: 90) == 80)
        #expect(wide.blockID(forWord: 90) == 64)
        for id in [0, 90, 100, 199] {
            let block = try #require(wide.blocks.first { $0.id == wide.blockID(forWord: id) })
            #expect(block.placements.contains { $0.id == id })
        }
        #expect(wide.blockID(forWord: -1) == nil)
        #expect(wide.blockID(forWord: 200) == nil)
    }

    @Test("Long unbroken tokens join without inserting spaces")
    func unbrokenTokens() throws {
        let text = String(repeating: "x", count: 260)
        let result = try layout(text, width: 300)
        #expect(result.blocks.count == 1)
        #expect(result.blocks[0].placements.map(\.frame.minX) == [0, 128, 256])
    }

    @Test("Font measurement bounds enormous tokens and changes with font size")
    func fontMetrics() throws {
        let document = try SpeechReaderDocument.build(String(repeating: "x", count: 1_000))
        let small = try SpeechReaderTypography(font: .systemFont(ofSize: 13)).layout(document: document, width: 200)
        let large = try SpeechReaderTypography(font: .systemFont(ofSize: 20)).layout(document: document, width: 200)
        #expect(small.blocks.flatMap(\.placements).allSatisfy { $0.frame.maxX <= 200 })
        #expect(large.blocks[0].height > small.blocks[0].height)
    }

    @Test("Reader measurement retains system font metrics instead of resolving a private font name")
    func systemFontMetrics() throws {
        let font = NSFont.systemFont(ofSize: 15)
        let text = "readable"
        let document = try SpeechReaderDocument.build(text)
        let layout = try SpeechReaderTypography(font: font).layout(document: document, width: 300)
        let expected = (text as NSString).size(withAttributes: [.font: font])
        let frame = try #require(layout.blocks.first?.placements.first?.frame)
        #expect(frame.width == ceil(expected.width))
        #expect(frame.height == ceil(expected.height))
    }

    @Test("Long documents have bounded lazy blocks and measure repeated words once")
    func longDocumentLayout() throws {
        let document = try SpeechReaderDocument.build(String(repeating: "one two three four five. ", count: 20_000))
        var measurements = 0
        let result = try SpeechReaderLayout.build(document: document, width: 40, spaceWidth: 1) {
            measurements += 1
            return CGSize(width: $0.count, height: 10)
        }
        #expect(measurements == 5)
        #expect(result.blocks.count > 1_000)
        #expect(result.blocks.allSatisfy { $0.lineCount <= 8 })
        #expect(result.blocks.flatMap(\.placements).count == 100_000)
        #expect(result.blockID(forWord: 99_999) == result.blocks.last?.id)
    }

    @Test("Unavailable widths and empty documents do not produce invalid geometry")
    func emptyAndInvalidWidths() throws {
        for width in [0, -1, Double.nan, .infinity] {
            #expect(try layout("text", width: width).blocks.isEmpty)
        }
        #expect(try layout(" \n ", width: 100).blocks.isEmpty)
    }

    @Test("Cancelled layout does not return partial results")
    func cancellation() async throws {
        let document = try SpeechReaderDocument.build("one two three")
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpeechReaderLayout.build(document: document, width: 10, spaceWidth: 1) {
                CGSize(width: $0.count, height: 10)
            }
        }
        do {
            _ = try await work.value
            Issue.record("Cancelled layout returned a result")
        } catch is CancellationError { }
    }
}
