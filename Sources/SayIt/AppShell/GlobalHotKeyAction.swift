import Foundation

enum GlobalHotKeyAction: UInt32, Hashable, Sendable {
    case readClipboard = 1
    case speakSelection = 2
}
