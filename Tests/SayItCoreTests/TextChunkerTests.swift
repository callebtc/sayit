import Testing
@testable import SayItCore

@Suite("Speech chunking")
struct TextChunkerTests {
    @Test("Chunks preserve sentence and paragraph boundaries")
    func preservesBoundaries() {
        let text = """
        First sentence. Second sentence is a little longer.

        A new paragraph begins here. It also has another sentence.
        """
        let chunks = TextChunker(targetCharacterCount: 45).chunks(for: text)

        #expect(chunks.count >= 3)
        #expect(chunks.first?.startsParagraph == true)
        #expect(chunks.contains { $0.text.hasPrefix("A new paragraph") && $0.startsParagraph })
        #expect(chunks.map(\.id) == Array(chunks.indices))
    }

    @Test("Oversized sentences split at readable boundaries")
    func splitsOversizedSentence() {
        let sentence = String(repeating: "readable words, ", count: 40) + "done."
        let chunks = TextChunker(
            targetCharacterCount: 100,
            hardCharacterLimit: 120
        ).chunks(for: sentence)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 120 })
        #expect(chunks.map(\.text).joined(separator: " ").contains("done."))
    }
}
