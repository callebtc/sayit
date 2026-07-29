import AppKit
import Foundation
import SayItCore

@MainActor
final class ServiceProvider: NSObject {
    @objc(saySelectedText:userData:error:)
    func saySelectedText(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let payload = PasteboardPayloadReader.payload(
            from: pasteboard,
            source: .service
        )
        guard payload.html != nil
                || payload.richText != nil
                || payload.plainText != nil else {
            errorPointer.pointee = "No readable text was selected."
            return
        }
        AppState.shared.receive(payload)
        _ = userData
    }
}
