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

    @Test("Model-aware fitting subdivides chunks without losing text")
    func respectsModelLimit() {
        let text = """
        A long opening sentence has several natural places where it can split. \
        The next sentence should also remain in the same continuous reading.
        """
        let chunks = TextChunker(
            targetCharacterCount: 200,
            hardCharacterLimit: 240
        ).chunks(for: text) { candidate in
            candidate.count <= 32
        }

        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.text.count <= 32 })
        #expect(chunks.first?.startsParagraph == true)
        #expect(chunks.dropFirst().allSatisfy { !$0.startsParagraph })
        #expect(
            chunks.flatMap { $0.text.split(separator: " ") }
                == text.split(separator: " ")
        )
        #expect(chunks.map(\.id) == Array(chunks.indices))
    }

    @Test("Adaptive subdivision makes progress for unbroken Unicode text")
    func splitsUnbrokenUnicodeText() {
        let chunk = SpeechChunk(
            id: 4,
            text: String(repeating: "界", count: 31),
            startsParagraph: true
        )
        let pieces = TextChunker().subchunks(of: chunk)

        #expect(pieces.count == 2)
        #expect(pieces.map(\.text).joined() == chunk.text)
        #expect(pieces[0].startsParagraph)
        #expect(!pieces[1].startsParagraph)
    }
}
