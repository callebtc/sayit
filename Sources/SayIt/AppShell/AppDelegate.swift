import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        do {
            try GlobalHotKeyManager.shared.register(
                AppState.shared.settings.globalShortcut
            )
        } catch {
            AppState.shared.presentError(
                "The Control–Option–S shortcut is already in use."
            )
        }
        Task {
            await AppState.shared.startup()
        }
        _ = notification
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregister()
        _ = notification
    }
}
