import Carbon
import Foundation

@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private static let signature: OSType = 0x5341_5949

    private var hotKeyReferences: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var handlerReference: EventHandlerRef?

    private init() {}

    func register(
        _ shortcut: GlobalShortcut,
        for action: GlobalHotKeyAction
    ) throws {
        unregister(action)
        try installHandlerIfNeeded()

        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: action.rawValue
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            removeHandlerIfUnused()
            throw CocoaError(.featureUnsupported)
        }
        hotKeyReferences[action] = reference
    }

    func unregister(_ action: GlobalHotKeyAction) {
        if let reference = hotKeyReferences.removeValue(forKey: action) {
            UnregisterEventHotKey(reference)
        }
        removeHandlerIfUnused()
    }

    func unregisterAll() {
        for reference in hotKeyReferences.values {
            UnregisterEventHotKey(reference)
        }
        hotKeyReferences.removeAll()
        removeHandlerIfUnused()
    }

    private func installHandlerIfNeeded() throws {
        guard handlerReference == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalHotKeyManager>
                .fromOpaque(context)
                .takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier
            )
            guard status == noErr,
                  identifier.signature == GlobalHotKeyManager.signature,
                  let action = GlobalHotKeyAction(rawValue: identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in
                manager.perform(action)
            }
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
    }

    private func perform(_ action: GlobalHotKeyAction) {
        switch action {
        case .readClipboard:
            AppState.shared.readClipboard()
        case .speakSelection:
            AppState.shared.speakSelectedText()
        }
    }

    private func removeHandlerIfUnused() {
        guard hotKeyReferences.isEmpty else { return }
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
    }
}
