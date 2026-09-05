public struct SpeechChunk: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let startsParagraph: Bool

    /// Character offsets in the cleaned source text represented by this chunk.
    public var sourceRange: Range<Int> {
        let lowerBound = sourceBoundaryOffsets[0]
        let upperBound = sourceBoundaryOffsets[sourceBoundaryOffsets.count - 1]
        return lowerBound..<upperBound
    }

    let sourceBoundaryOffsets: [Int]

    public init(
        id: Int,
        text: String,
        startsParagraph: Bool,
        sourceRange: Range<Int>
    ) {
        precondition(!text.isEmpty)
        precondition(sourceRange.lowerBound >= 0)
        precondition(sourceRange.count == text.count)
        self.id = id
        self.text = text
        self.startsParagraph = startsParagraph
        sourceBoundaryOffsets = Array(
            sourceRange.lowerBound...sourceRange.upperBound
        )
    }

    init(
        id: Int,
        text: String,
        startsParagraph: Bool,
        sourceBoundaryOffsets: [Int]
    ) {
        precondition(!text.isEmpty)
        precondition(sourceBoundaryOffsets.first.map { $0 >= 0 } == true)
        precondition(sourceBoundaryOffsets.count == text.count + 1)
        precondition(
            zip(
                sourceBoundaryOffsets,
                sourceBoundaryOffsets.dropFirst()
            ).allSatisfy { $0 <= $1 }
        )
        self.id = id
        self.text = text
        self.startsParagraph = startsParagraph
        self.sourceBoundaryOffsets = sourceBoundaryOffsets
    }

    func slice(
        id: Int,
        textRange: Range<String.Index>,
        characterRange: Range<Int>? = nil,
        startsParagraph: Bool
    ) -> SpeechChunk {
        let lowerOffset = characterRange?.lowerBound ?? text.distance(
            from: text.startIndex,
            to: textRange.lowerBound
        )
        let upperOffset = characterRange?.upperBound ?? text.distance(
            from: text.startIndex,
            to: textRange.upperBound
        )
        return SpeechChunk(
            id: id,
            text: String(text[textRange]),
            startsParagraph: startsParagraph,
            sourceBoundaryOffsets: Array(
                sourceBoundaryOffsets[lowerOffset...upperOffset]
            )
        )
    }

    func reidentified(
        as id: Int,
        startsParagraph: Bool
    ) -> SpeechChunk {
        SpeechChunk(
            id: id,
            text: text,
            startsParagraph: startsParagraph,
            sourceBoundaryOffsets: sourceBoundaryOffsets
        )
    }
}
