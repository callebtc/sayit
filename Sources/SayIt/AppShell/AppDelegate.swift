import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExposeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ] {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    self.updateDockPresence()
                }
            }
        }
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard AppState.shared.selectionService
                    .accessibilityIsTrusted != nil else {
                    return
                }
                await AppState.shared.refreshSelectionAccessibilityAccess()
            }
        }

        do {
            try GlobalHotKeyManager.shared.register(
                AppState.shared.settings.globalShortcut,
                for: .readClipboard
            )
        } catch {
            AppState.shared.presentError(
                "The Control–Option–V shortcut is already in use."
            )
        }
        do {
            try GlobalHotKeyManager.shared.register(
                AppState.shared.settings.selectionShortcut,
                for: .speakSelection
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

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        Task {
            await AppState.shared.terminateBackgroundServiceForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregisterAll()
        _ = notification
    }

    private func updateDockPresence() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let hasVisibleWindow = NSApp.windows.contains { window in
                    window.isVisible && window.canBecomeMain
                }
                let target: NSApplication.ActivationPolicy =
                    hasVisibleWindow ? .regular : .accessory
                if NSApp.activationPolicy() != target {
                    NSApp.setActivationPolicy(target)
                }
            }
        }
    }
}
