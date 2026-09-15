import SwiftUI

@main
@MainActor
struct SayItApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var state = AppState.shared

    var body: some Scene {
        Window("Say It", id: AppWindowID.main) {
            SettingsRootView()
                .tabViewStyle(.sidebarAdaptable)
                .environment(state)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    WindowActivator.prepareForWindowPresentation()
                    openWindow(id: AppWindowID.main)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarRootView()
                .environment(state)
        } label: {
            MenuBarLabel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)

        Window("History", id: AppWindowID.history) {
            HistoryView()
                .environment(state)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to Say It", id: AppWindowID.onboarding) {
            OnboardingView()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
