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

    @Test("Copies when accessibility cannot expose selected text")
    func copyFallbackForMissingAccessibilitySelection() async {
        var events: [String] = []
        let copiedContent = PasteboardContent(
            plainText: "Selected Safari text"
        )

        let response = await SelectionCaptureFlow.perform(
            retryDelays: [.zero, .zero, .zero],
            accessibilitySelection: {
                events.append("accessibility")
                return .noSelection
            },
            copiedSelection: {
                events.append("copy")
                return .selectedContent(copiedContent)
            }
        )

        #expect(response == .selectedContent(copiedContent))
        #expect(events == ["accessibility", "copy"])
    }

    @Test("Retries accessibility after the copy fallback finds no text")
    func retriesAfterEmptyCopyFallback() async {
        var events: [String] = []

        let response = await SelectionCaptureFlow.perform(
            retryDelays: [.zero, .zero, .zero],
            accessibilitySelection: {
                events.append("accessibility")
                return .noSelection
            },
            copiedSelection: {
                events.append("copy")
                return nil
            }
        )

        #expect(response == .noSelection)
        #expect(
            events == [
                "accessibility",
                "copy",
                "accessibility",
                "accessibility"
            ]
        )
    }

    @Test("Keeps accessibility text when copying is unavailable")
    func accessibilityTextFallback() async {
        var copyAttempts = 0

        let response = await SelectionCaptureFlow.perform(
            retryDelays: [.zero],
            accessibilitySelection: {
                .selectedText("Selected text")
            },
            copiedSelection: {
                copyAttempts += 1
                return nil
            }
        )

        #expect(response == .selectedText("Selected text"))
        #expect(copyAttempts == 1)
    }

    @Test("Does not copy after a terminal accessibility response")
    func preservesTerminalAccessibilityResponse() async {
        var copyAttempts = 0

        let response = await SelectionCaptureFlow.perform(
            retryDelays: [.zero],
            accessibilitySelection: {
                .selectionTooLong(maximumCharacters: 10)
            },
            copiedSelection: {
                copyAttempts += 1
                return nil
            }
        )

        #expect(response == .selectionTooLong(maximumCharacters: 10))
        #expect(copyAttempts == 0)
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
