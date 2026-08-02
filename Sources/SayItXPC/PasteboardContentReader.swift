import AppKit
import SayItProtocol

public enum PasteboardContentReader {
    public static func content(
        from pasteboard: NSPasteboard
    ) -> PasteboardContent? {
        let content = PasteboardContent(
            html: pasteboard.data(forType: .html),
            richText: pasteboard.data(forType: .rtf)
                ?? pasteboard.data(forType: .rtfd),
            plainText: pasteboard.string(forType: .string)
                ?? pasteboard.string(
                    forType: .init("public.utf8-plain-text")
                )
        )
        guard content.html != nil
            || content.richText != nil
            || content.plainText != nil else {
            return nil
        }
        return content
    }
}
