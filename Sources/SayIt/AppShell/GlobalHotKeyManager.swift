import Carbon
import Foundation

@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyReference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?

    private init() {}

    func register(_ shortcut: GlobalShortcut) throws {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                AppState.shared.readClipboard()
            }
            _ = manager
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerReference
        )
        guard installStatus == noErr else {
            throw CocoaError(.featureUnsupported)
        }

        let identifier = EventHotKeyID(signature: 0x5341_5949, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registerStatus == noErr else {
            unregister()
            throw CocoaError(.featureUnsupported)
        }
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
    }
}
