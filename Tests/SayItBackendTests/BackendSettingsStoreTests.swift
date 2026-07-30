import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@MainActor
@Suite("Backend settings storage")
struct BackendSettingsStoreTests {
    @Test("A failed atomic write does not change in-memory settings")
    func failedWritePreservesCurrentValue() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
        let store = BackendSettingsStore(directory: missingDirectory)
        let original = store.value
        var updated = original
        updated.speakingPace = SpeakingPace.fast.rawValue

        #expect(throws: (any Error).self) {
            try store.update(updated)
        }
        #expect(store.value == original)
    }
}
