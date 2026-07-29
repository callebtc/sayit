import SwiftUI

@main
@MainActor
struct SayItApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(state)
        } label: {
            MenuBarLabel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environment(state)
                .frame(minWidth: 720, minHeight: 500)
        }

        WindowGroup("History", id: "history") {
            HistoryView()
                .environment(state)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)
    }
}
