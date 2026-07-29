import AppKit
import Foundation
import SayItCore

enum PasteboardPayloadReader {
    static func payload(
        from pasteboard: NSPasteboard,
        source: TriggerSource
    ) -> TextSourcePayload {
        let html = pasteboard.data(forType: .html)
        let richText = pasteboard.data(forType: .rtf)
            ?? pasteboard.data(forType: .rtfd)
        let plainText = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: .init("public.utf8-plain-text"))
        return TextSourcePayload(
            source: source,
            html: html,
            richText: richText,
            plainText: plainText
        )
    }
}
