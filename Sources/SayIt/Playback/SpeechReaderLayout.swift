import Foundation

/// Wrap first, then group complete lines for lazy rendering. Storage boundaries
/// must never become line breaks, and audio arrivals must never trigger layout.
struct SpeechReaderLayout: Sendable {
    static let maximumLinesPerBlock = 8
    static let lineSpacing: Double = 3
    static let paragraphSpacing: Double = 8

    struct Placement: Identifiable, Sendable {
        let id: Int
        let frame: CGRect
    }

    struct Block: Identifiable, Sendable {
        let id: Int
        let placements: [Placement]
        let height: Double
        let spacingBefore: Double
        let lineCount: Int
    }

    let blocks: [Block]
    let blockIDsByWord: [Int]
    static let empty = Self(blocks: [], blockIDsByWord: [])

    static func build(
        document: SpeechReaderDocument,
        width: Double,
        spaceWidth: Double,
        measure: (String) -> CGSize
    ) throws -> Self {
        guard width.isFinite, width > 0 else { return .empty }
        var blocks: [Block] = []
        var blockIDs: [Int] = []
        var placements: [Placement] = []
        var blockID = 0
        var x: Double = 0
        var y: Double = 0
        var rowHeight: Double = 0
        var lineCount = 1
        var spacingBefore: Double = 0
        var measurements: [String: CGSize] = [:]

        func flush() {
            guard !placements.isEmpty else { return }
            blocks.append(Block(
                id: blockID, placements: placements, height: y + rowHeight,
                spacingBefore: spacingBefore, lineCount: lineCount
            ))
            placements = []
        }

        for word in document.tokens {
            try Task.checkCancellation()
            let size: CGSize
            if let cached = measurements[word.text] {
                size = cached
            } else {
                size = measure(word.text)
                measurements[word.text] = size
            }
            let gap = x > 0 && !word.joinsPrevious ? spaceWidth : 0
            if !placements.isEmpty,
               word.newlinesBefore > 0 || (x > 0 && x + gap + size.width > width) {
                let spacing = lineSpacing + (word.newlinesBefore > 1 ? paragraphSpacing : 0)
                if lineCount >= maximumLinesPerBlock {
                    flush()
                    blockID = word.id
                    spacingBefore = spacing
                    y = 0
                    lineCount = 1
                } else {
                    y += rowHeight + spacing
                    lineCount += 1
                }
                x = 0
                rowHeight = 0
            }
            if x > 0 && !word.joinsPrevious { x += spaceWidth }
            placements.append(Placement(
                id: word.id, frame: CGRect(x: x, y: y, width: size.width, height: size.height)
            ))
            blockIDs.append(blockID)
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        flush()
        return Self(blocks: blocks, blockIDsByWord: blockIDs)
    }

    func blockID(forWord id: Int) -> Int? {
        blockIDsByWord.indices.contains(id) ? blockIDsByWord[id] : nil
    }
}
