import Foundation

/// Only physical helper operations and time vary in app lifecycle tests. The
/// preparation/recovery ordering remains in the production AppState methods.
@MainActor
struct AppLifecycleOperations {
    var clock: LifecycleClock
    var rememberSelectionForUpdate: () -> Void
    var restoreSelection: () async -> Void
    var terminateSelectionForUpdate: (Date) async throws -> Void
    var terminateBackgroundForUpdate: (Date) async throws -> Void
    var terminateSelectionForQuit: () async -> Void
    var terminateBackgroundForQuit: () async -> Void

    static func live(
        selection: SelectionServiceController,
        background: BackgroundServiceController
    ) -> AppLifecycleOperations {
        AppLifecycleOperations(
            clock: .system,
            rememberSelectionForUpdate: {
                if selection.wasRunning {
                    UserDefaults.standard.set(true, forKey: "restoreSelectionAfterUpdate")
                }
            },
            restoreSelection: { await selection.restoreAfterUpdate() },
            terminateSelectionForUpdate: { try await selection.terminateForUpdate(deadline: $0) },
            terminateBackgroundForUpdate: { try await background.terminateForUpdate(deadline: $0) },
            terminateSelectionForQuit: { await selection.terminateForQuit() },
            terminateBackgroundForQuit: { await background.terminateForQuit() }
        )
    }
}
