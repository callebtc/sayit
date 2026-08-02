import AppKit
import SayItProtocol
import Testing
import SayItXPC

@Suite("Selected text reader")
struct SelectedTextReaderTests {
    @Test("Reads all standard text representations from one pasteboard path")
    func readsPasteboardRepresentations() throws {
        let pasteboard = NSPasteboard(
            name: .init("selection-reader-tests-\(UUID().uuidString)")
        )
        let html = Data("<p>First paragraph.</p><p>Second paragraph.</p>".utf8)
        let richText = Data("mock rich text".utf8)
        let item = NSPasteboardItem()
        item.setString(
            "First paragraph.\n\nSecond paragraph.",
            forType: .string
        )
        item.setData(html, forType: .html)
        item.setData(richText, forType: .rtf)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))

        let content = try #require(
            PasteboardContentReader.content(from: pasteboard)
        )

        #expect(content.plainText == "First paragraph.\n\nSecond paragraph.")
        #expect(content.html == html)
        #expect(content.richText == richText)
    }

    @Test("Searches beyond eight accessibility ancestors")
    func deepAncestorSelection() {
        let result = firstValueAlongAncestorChain(
            from: 0,
            value: { $0 == 12 ? "Selected text" : nil },
            parent: { $0 + 1 }
        )

        #expect(result == "Selected text")
    }

    @Test("Stops malformed accessibility parent cycles at the safety limit")
    func malformedParentCycle() {
        var visitedElementCount = 0

        let result: String? = firstValueAlongAncestorChain(
            from: 0,
            maximumElementCount: 5,
            value: { _ in
                visitedElementCount += 1
                return nil
            },
            parent: { $0 }
        )

        #expect(result == nil)
        #expect(visitedElementCount == 5)
    }
}
