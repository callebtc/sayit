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

        Window("Say It Settings", id: AppWindowID.settings) {
            SettingsRootView()
                .environment(state)
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

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
