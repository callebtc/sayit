import AppKit
import Carbon
import Foundation

struct GlobalShortcut: Equatable, Sendable {
    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyLabel: "V"
    )

    static let defaultSelectionShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyLabel: "S"
    )

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    init(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        keyLabel: String
    ) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        var modifiers: UInt32 = 0
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        guard modifiers != 0,
              let characters = event.charactersIgnoringModifiers,
              let firstCharacter = characters.first else {
            return nil
        }
        self.init(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: String(firstCharacter).uppercased()
        )
    }

    var displayName: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 {
            symbols += "⌃"
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            symbols += "⌥"
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            symbols += "⇧"
        }
        if carbonModifiers & UInt32(cmdKey) != 0 {
            symbols += "⌘"
        }
        return symbols + keyLabel
    }
}
