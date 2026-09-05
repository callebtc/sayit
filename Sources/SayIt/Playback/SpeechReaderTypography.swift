import AppKit

/// The renderer and background measurement use the same explicit font metrics.
struct SpeechReaderTypography: Equatable, Sendable {
    let pointSize: Double

    init(font: NSFont) {
        pointSize = font.pointSize
    }

    var font: NSFont {
        // Private system font names are not round-trippable through NSFont(name:).
        NSFont.systemFont(ofSize: pointSize)
    }

    func layout(document: SpeechReaderDocument, width: Double) throws -> SpeechReaderLayout {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let spaceWidth = (" " as NSString).size(withAttributes: attributes).width
        return try SpeechReaderLayout.build(document: document, width: width, spaceWidth: spaceWidth) { text in
            let natural = (text as NSString).size(withAttributes: attributes)
            guard natural.width > width else {
                return CGSize(width: ceil(natural.width), height: ceil(natural.height))
            }
            let wrapped = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            return CGSize(width: width, height: ceil(wrapped.height))
        }
    }
}
