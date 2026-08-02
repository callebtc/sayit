import AppKit
import Foundation
import SayItCore
import SayItProtocol
import SayItXPC

enum PasteboardPayloadReader {
    static func payload(
        from pasteboard: NSPasteboard,
        source: TriggerSource
    ) -> TextSourcePayload {
        guard let content = PasteboardContentReader.content(
            from: pasteboard
        ) else {
            return TextSourcePayload(source: source)
        }
        return TextSourcePayload(source: source, content: content)
    }
}

extension TextSourcePayload {
    init(source: TriggerSource, content: PasteboardContent) {
        self.init(
            source: source,
            html: content.html,
            richText: content.richText,
            plainText: content.plainText
        )
    }
}
