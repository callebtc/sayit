#if DEBUG || SAYIT_LOCAL_BUILD
import Foundation
import SayItProtocol
import SayItXPC

enum DevelopmentSelectionServiceLauncher {
    private static let label = "sh.sayit.mac.selection.debug"
    private static let legacyLabel = "com.sayit.mac.selection.debug"

    static func ensureRunning(agentURL: URL) async throws {
        removeLegacyJobIfNeeded()
        try await jobManager(agentURL: agentURL).ensureRunning()
    }

    static func unregister() throws {
        try jobManager(
            agentURL: URL(filePath: "/dev/null")
        ).shutdown()
    }

    private static func removeLegacyJobIfNeeded() {
        guard ServiceJobManager.printJob(label: legacyLabel)?.status == 0 else {
            return
        }
        try? ServiceJobManager.shutdown(label: legacyLabel)
    }

    private static func jobManager(agentURL: URL) -> ServiceJobManager {
        ServiceJobManager(
            label: label,
            machServiceName: SayItServiceIdentifiers.selectionMachService,
            agentURL: agentURL,
            logURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).log"),
            propertyListURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).plist")
        )
    }
}
#endif
