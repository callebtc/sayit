import AppKit
import Foundation
import Sparkle

@main
@MainActor
struct UpdateFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.appearance = NSAppearance(named: .aqua)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private let updates = UpdateController()
    private var root: URL {
        URL(filePath: Bundle.main.object(forInfoDictionaryKey: "FixtureRoot") as! String)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        if version == "2" {
            Task {
                do {
                    for index in 1...2 {
                        try await bootstrap(index)
                    }
                    try Data("installed and relaunched".utf8).write(to: root.appending(path: "success"))
                } catch {
                    try? Data("helper restart failed".utf8).write(to: root.appending(path: "failure"))
                }
                NSApp.terminate(nil)
            }
            return
        }
        updates.isUserInteracting = { true }
        updates.prepareForInstallation = { [self] in
            let deadline = Date.now.addingTimeInterval(15)
            for index in 1...2 {
                try await ServiceJobTermination.stop(label: label(index), deadline: deadline)
            }
            try Data("helpers stopped".utf8).write(to: root.appending(path: "prepared"))
        }
        updates.start()
        updates.checkForUpdates()
        Task {
            while updates.phase != .available && updates.phase != .failed {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if updates.phase == .available {
                if let view = NSApp.windows.first(where: { $0.title == "Software Update" })?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: root.appending(path: "update-dialog.png"))
                }
                updates.updateNow()
            }
            while true {
                if updates.phase == .failed || updates.phase == .unavailable {
                    try? Data(updates.status.utf8).write(to: root.appending(path: "failure"))
                    NSApp.terminate(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func label(_ index: Int) -> String {
        "sh.sayit.update-fixture.\(index)"
    }

    private func bootstrap(_ index: Int) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", root.appending(path: "helper-\(index).plist").path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CocoaError(.executableLoad) }
    }
}
