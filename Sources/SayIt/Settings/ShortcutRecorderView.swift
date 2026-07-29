import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let shortcut: GlobalShortcut
    let onRecord: (GlobalShortcut) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Button(isRecording ? "Type shortcut…" : shortcut.displayName) {
            beginRecording()
        }
        .font(.body.monospaced())
        .buttonStyle(.bordered)
        .accessibilityLabel("Global shortcut")
        .accessibilityValue(
            isRecording ? "Waiting for shortcut" : shortcut.displayName
        )
        .onDisappear(perform: stopRecording)
    }

    private func beginRecording() {
        stopRecording()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let shortcut = GlobalShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            onRecord(shortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }
}
