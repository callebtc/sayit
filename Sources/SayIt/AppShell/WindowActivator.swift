import AppKit

enum WindowActivator {
    @MainActor
    static func prepareForWindowPresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
