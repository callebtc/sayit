import Testing
import SayItXPC

@Suite("Selected text reader")
struct SelectedTextReaderTests {
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
